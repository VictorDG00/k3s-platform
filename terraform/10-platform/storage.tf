# Storage: rancher/local-path-provisioner v0.0.37.
#
# Why a vendored manifest and not Helm: the project publishes no official chart
# (upstream only documents `kubectl apply` of deploy/local-path-storage.yaml;
# third-party charts exist, we do not want to trust them). The upstream YAML
# lives in vendor/ with URL + sha256 in its header, unmodified. Here we only
# override what must change: StorageClass (default, Retain), ConfigMap (k3s
# path, pinned busybox) and the Deployment (resources + image digest).
# Everything else is applied as-is.

locals {
  lpp_docs = provider::kubernetes::manifest_decode_multi(file("${path.module}/vendor/local-path-storage-v0.0.37.yaml"))
  lpp_by_key = {
    for d in local.lpp_docs : "${d.kind}/${d.metadata.name}" => d
  }

  lpp_image     = "docker.io/rancher/local-path-provisioner:v0.0.37@sha256:e757967a5ec338f6a9b371c5a9688bedaa8c3578ea3dd4db329ea0084be0a86f"
  busybox_image = "docker.io/library/busybox:1.37.0@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"

  # Upstream objects that are NOT applied as-is.
  lpp_overridden = ["StorageClass/local-path", "ConfigMap/local-path-config", "Deployment/local-path-provisioner"]
  lpp_as_is      = { for k, d in local.lpp_by_key : k => d if !contains(local.lpp_overridden, k) }

  lpp_deploy = local.lpp_by_key["Deployment/local-path-provisioner"]
}

resource "kubernetes_manifest" "lpp_as_is" {
  for_each = local.lpp_as_is
  manifest = each.value
}

resource "kubernetes_manifest" "lpp_config" {
  depends_on = [kubernetes_manifest.lpp_as_is]

  manifest = merge(local.lpp_by_key["ConfigMap/local-path-config"], {
    data = {
      "config.json" = jsonencode({
        nodePathMap = [{
          node  = "DEFAULT_PATH_FOR_NON_LISTED_NODES"
          paths = ["/var/lib/rancher/k3s/storage"]
        }]
      })
      # Same as upstream (mkdir 0777: pods run with different uids and a
      # hostPath ignores fsGroup), plus chmod 0711 on the parent directory:
      # non-root users cannot list the PVs, only enter a directory whose
      # (uuid) name they already know.
      setup    = <<-EOT
        #!/bin/sh
        set -eu
        mkdir -m 0777 -p "$VOL_DIR"
        chmod 0711 "$(dirname "$VOL_DIR")"
      EOT
      teardown = local.lpp_by_key["ConfigMap/local-path-config"].data.teardown
      "helperPod.yaml" = replace(
        local.lpp_by_key["ConfigMap/local-path-config"].data["helperPod.yaml"],
        "        image: docker.io/library/busybox\n",
        "        image: ${local.busybox_image}\n        resources:\n          requests:\n            cpu: 10m\n            memory: 16Mi\n          limits:\n            memory: 64Mi\n",
      )
    }
  })
}

resource "kubernetes_manifest" "lpp_deployment" {
  depends_on = [kubernetes_manifest.lpp_as_is, kubernetes_manifest.lpp_config]

  manifest = merge(local.lpp_deploy, {
    spec = merge(local.lpp_deploy.spec, {
      template = merge(local.lpp_deploy.spec.template, {
        spec = merge(local.lpp_deploy.spec.template.spec, {
          containers = [merge(local.lpp_deploy.spec.template.spec.containers[0], {
            image = local.lpp_image
            resources = {
              requests = { cpu = "10m", memory = "32Mi" }
              limits   = { memory = "64Mi" }
            }
          })]
        })
      })
    })
  })
}

# Retain: deleting a PVC/release does not delete the data under
# /var/lib/rancher/k3s/storage (the PV goes Released, cleanup is manual).
# WaitForFirstConsumer as in upstream.
resource "kubernetes_manifest" "storage_class" {
  depends_on = [kubernetes_manifest.lpp_deployment]

  manifest = {
    apiVersion = "storage.k8s.io/v1"
    kind       = "StorageClass"
    metadata = {
      name        = "local-path"
      annotations = { "storageclass.kubernetes.io/is-default-class" = "true" }
    }
    provisioner       = "rancher.io/local-path"
    volumeBindingMode = "WaitForFirstConsumer"
    reclaimPolicy     = "Retain"
  }
}
