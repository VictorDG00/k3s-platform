# Daily backup of what is irreplaceable in the cluster, shipped to
# S3-compatible object storage through an rclone `crypt` remote (client-side
# encryption) named `offsite`, layered over bucket `example-backups`:
#   (a) the sealed-secrets master keys (without them, the SealedSecrets in git
#       can no longer be opened);
#   (b) the k3s datastore (sqlite): a consistent state.db + token +
#       encryption-config.json (secrets-encryption is on: without that file a
#       restored state.db cannot decrypt Secrets) + server/tls (the CA and the
#       ServiceAccount signing key; without them a restore mints a new CA and
#       invalidates kubeconfigs and pod tokens).
#
# The `rclone-offsite` Secret (key rclone.conf) is NOT managed here: the
# operator creates it outside Terraform (see docs/restore.md), otherwise its
# content would land in the state.
#
# Runs at 04:10 UTC.

locals {
  # Digests of public upstream images, checked against the registry when pinned.
  backup_rclone_image = "docker.io/rclone/rclone:1.75.1@sha256:45401ad7410db1d67ffdb58e19059ad20b0d8e0285a60e38bbec55cc1019c7a5"
  backup_sqlite_image = "docker.io/keinos/sqlite3:3.53.4@sha256:6addaf450aea7e098e7d6f059d43501c317ec70494c1ace3cc94bfe1631cbfa5"
  backup_curl_image   = "docker.io/curlimages/curl:8.15.0@sha256:4026b29997dc7c823b51c164b71e2b51e0fd95cce4601f78202c513d97da2922"
  backup_dest         = "offsite:example-backups/k3s"
  k3s_server_dir      = "/var/lib/rancher/k3s/server"
}

resource "kubernetes_service_account_v1" "backup" {
  metadata {
    name      = "k3s-backup"
    namespace = kubernetes_namespace_v1.platform["backup"].metadata[0].name
  }
}

# Role (not ClusterRole) in the sealed-secrets namespace. RBAC cannot filter by
# label: the permission covers every Secret in that namespace. Acceptable
# because only the controller keys (and the Helm release Secret) live there;
# the label filter is applied in the init container's request.
resource "kubernetes_role_v1" "backup_read_keys" {
  metadata {
    name      = "backup-read-sealed-keys"
    namespace = kubernetes_namespace_v1.platform["sealed-secrets"].metadata[0].name
  }
  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_role_binding_v1" "backup_read_keys" {
  metadata {
    name      = "backup-read-sealed-keys"
    namespace = kubernetes_namespace_v1.platform["sealed-secrets"].metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.backup_read_keys.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.backup.metadata[0].name
    namespace = kubernetes_namespace_v1.platform["backup"].metadata[0].name
  }
}

resource "kubernetes_config_map_v1" "backup_scripts" {
  metadata {
    name      = "backup-scripts"
    namespace = kubernetes_namespace_v1.platform["backup"].metadata[0].name
  }
  data = {
    "sealed-keys.sh" = <<-EOT
      #!/bin/sh
      set -eu
      SA=/var/run/secrets/kubernetes.io/serviceaccount
      curl -fsS --cacert "$SA/ca.crt" \
        -H "Authorization: Bearer $(cat $SA/token)" \
        "https://kubernetes.default.svc/api/v1/namespaces/sealed-secrets/secrets?labelSelector=sealedsecrets.bitnami.com%2Fsealed-secrets-key" \
        -o /work/sealed-secrets-keys.json
      # With no key at all the backup is useless: fail loudly.
      grep -q '"sealedsecrets.bitnami.com/sealed-secrets-key"' /work/sealed-secrets-keys.json
      # Readable by the upload container (another uid). Only the owner can chmod.
      chmod 0644 /work/sealed-secrets-keys.json
    EOT

    "k3s-snapshot.sh" = <<-EOT
      #!/bin/sh
      set -eu
      umask 022
      src=/k3s/db/state.db

      backup() { # $1 = banco de origem; .backup do sqlite = copia online consistente
        rm -f /work/state.db
        sqlite3 "$1" ".timeout 30000" ".backup '/work/state.db'"
      }

      # Path 1: straight from the read-only mount, via URI mode=ro.
      if ! backup "file:$src?mode=ro"; then
        # Path 2 (fallback): WAL on a read-only mount can fail. Copy
        # state.db + -wal + -shm to scratch and run .backup on the copy.
        echo "WARNING: direct .backup failed; using a copy of state.db/-wal/-shm" >&2
        mkdir -p /scratch/db
        cp "$src" /scratch/db/state.db
        for ext in -wal -shm; do
          if [ -f "$src$ext" ]; then cp "$src$ext" "/scratch/db/state.db$ext"; fi
        done
        backup /scratch/db/state.db
      fi

      # On BOTH paths: a torn copy = integrity_check fails = the job fails.
      test "$(sqlite3 /work/state.db 'PRAGMA integrity_check;')" = ok

      cp /k3s/token /work/token
      cp /k3s/encryption-config.json /work/encryption-config.json
      tar czf /work/tls.tgz -C /k3s tls
      # The upload container runs non-root: make files readable (ephemeral
      # emptyDir, visible only to this pod). Only this container's own files:
      # without CAP_FOWNER even root cannot chmod the sealed-keys file (other uid).
      chmod 0644 /work/state.db /work/token /work/encryption-config.json /work/tls.tgz
    EOT

    "upload.sh" = <<-EOT
      #!/bin/sh
      set -eu
      ts=$(date -u +%Y%m%dT%H%M%SZ)
      dest="${local.backup_dest}/$ts"
      # `copy`, never `sync`; --immutable never overwrites. The bucket has a 30-day
      # object lock and nothing here deletes anything out there.
      rclone copy /work "$dest" --transfers 2 --immutable
      # cryptcheck verifies content (hash of the encrypted file), not just size.
      rclone cryptcheck /work "$dest" --one-way
      echo "k3s-backup: ok $dest"
    EOT
  }
}

resource "kubernetes_cron_job_v1" "k3s_backup" {
  metadata {
    name      = "k3s-backup"
    namespace = kubernetes_namespace_v1.platform["backup"].metadata[0].name
  }

  spec {
    schedule                      = "10 4 * * *"
    timezone                      = "UTC"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3

    job_template {
      metadata {}
      spec {
        backoff_limit              = 1
        active_deadline_seconds    = 1800
        ttl_seconds_after_finished = 604800

        template {
          metadata {}
          spec {
            service_account_name = kubernetes_service_account_v1.backup.metadata[0].name
            restart_policy       = "Never"

            # 1) sealed-secrets keys, via the API (uid 100 of the curl image).
            init_container {
              name    = "sealed-keys"
              image   = local.backup_curl_image
              command = ["/bin/sh", "/scripts/sealed-keys.sh"]
              resources {
                requests = { cpu = "5m", memory = "16Mi" }
                limits   = { memory = "32Mi" }
              }
              security_context {
                allow_privilege_escalation = false
                read_only_root_filesystem  = true
                run_as_non_root            = true
                run_as_user                = 100
                capabilities { drop = ["ALL"] }
              }
              volume_mount {
                name       = "work"
                mount_path = "/work"
              }
              volume_mount {
                name       = "scripts"
                mount_path = "/scripts"
                read_only  = true
              }
            }

            # 2) k3s snapshot. Runs as ROOT because state.db, token and
            # encryption-config.json are 0600 root on the host. No capabilities
            # and ALL hostPaths read-only: the pod cannot write to the cluster
            # datastore.
            init_container {
              name    = "k3s-snapshot"
              image   = local.backup_sqlite_image
              command = ["/bin/sh", "/scripts/k3s-snapshot.sh"]
              resources {
                requests = { cpu = "10m", memory = "32Mi" }
                limits   = { memory = "256Mi" }
              }
              security_context {
                allow_privilege_escalation = false
                read_only_root_filesystem  = true
                run_as_user                = 0
                capabilities { drop = ["ALL"] }
              }
              volume_mount {
                name       = "work"
                mount_path = "/work"
              }
              volume_mount {
                name       = "tmp"
                mount_path = "/tmp"
              }
              volume_mount {
                name       = "scripts"
                mount_path = "/scripts"
                read_only  = true
              }
              volume_mount {
                name       = "scratch"
                mount_path = "/scratch"
              }
              volume_mount {
                name       = "k3s-db"
                mount_path = "/k3s/db"
                read_only  = true
              }
              volume_mount {
                name       = "k3s-token"
                mount_path = "/k3s/token"
                read_only  = true
              }
              volume_mount {
                name       = "k3s-cred"
                mount_path = "/k3s/encryption-config.json"
                read_only  = true
              }
              volume_mount {
                name       = "k3s-tls"
                mount_path = "/k3s/tls"
                read_only  = true
              }
            }

            # 3) upload. Non-root.
            container {
              name    = "upload"
              image   = local.backup_rclone_image
              command = ["/bin/sh", "/scripts/upload.sh"]
              env {
                name  = "RCLONE_CONFIG"
                value = "/rclone/rclone.conf"
              }
              resources {
                requests = { cpu = "10m", memory = "64Mi" }
                limits   = { memory = "256Mi" }
              }
              security_context {
                allow_privilege_escalation = false
                read_only_root_filesystem  = true
                run_as_non_root            = true
                run_as_user                = 65534
                run_as_group               = 65534
                capabilities { drop = ["ALL"] }
              }
              volume_mount {
                name       = "work"
                mount_path = "/work"
                read_only  = true
              }
              volume_mount {
                name       = "tmp"
                mount_path = "/tmp"
              }
              volume_mount {
                name       = "scripts"
                mount_path = "/scripts"
                read_only  = true
              }
              volume_mount {
                name       = "rclone"
                mount_path = "/rclone"
                read_only  = true
              }
            }

            volume {
              name = "work"
              empty_dir {
                size_limit = "4Gi"
              }
            }
            volume {
              name = "scratch"
              empty_dir {
                size_limit = "4Gi"
              }
            }
            volume {
              name = "tmp"
              empty_dir {
                size_limit = "256Mi"
              }
            }
            volume {
              name = "scripts"
              config_map {
                name         = kubernetes_config_map_v1.backup_scripts.metadata[0].name
                default_mode = "0555"
              }
            }
            # Created by the operator, outside Terraform.
            volume {
              name = "rclone"
              secret {
                secret_name  = "rclone-offsite"
                default_mode = "0444"
              }
            }
            volume {
              name = "k3s-db"
              host_path {
                path = "${local.k3s_server_dir}/db"
                type = "Directory"
              }
            }
            volume {
              name = "k3s-token"
              host_path {
                path = "${local.k3s_server_dir}/token"
                type = "File"
              }
            }
            volume {
              name = "k3s-cred"
              host_path {
                path = "${local.k3s_server_dir}/cred/encryption-config.json"
                type = "File"
              }
            }
            volume {
              name = "k3s-tls"
              host_path {
                path = "${local.k3s_server_dir}/tls"
                type = "Directory"
              }
            }
          }
        }
      }
    }
  }
}
