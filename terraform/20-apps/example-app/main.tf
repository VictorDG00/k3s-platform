locals {
  app_labels = { "app.kubernetes.io/name" = "example-app" }
  db_labels  = { "app.kubernetes.io/name" = "example-db" }
}

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = var.namespace
    labels = {
      "platform.example.com/name"    = var.namespace
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

# Sealed secrets committed to git (encrypted with the cluster's public key).
# Seal with kubeseal, see sealed/example-db.yaml for the shape. The controller
# turns each into a plain Secret inside the cluster.
resource "kubernetes_manifest" "secret" {
  for_each   = toset(["example-db", "example-app"])
  manifest   = yamldecode(file("${path.module}/sealed/${each.key}.yaml"))
  depends_on = [kubernetes_namespace_v1.this]
}

# --- Postgres -----------------------------------------------------------------
resource "kubernetes_stateful_set_v1" "db" {
  metadata {
    name      = "postgres"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }
  spec {
    service_name = "db"
    replicas     = 1
    selector {
      match_labels = local.db_labels
    }
    template {
      metadata {
        labels = local.db_labels
      }
      spec {
        automount_service_account_token = false
        container {
          name  = "postgres"
          image = var.postgres_image
          env_from {
            secret_ref {
              name = "example-db"
            }
          }
          env {
            name  = "PGDATA"
            value = "/var/lib/postgresql/data/pgdata"
          }
          port {
            container_port = 5432
          }
          resources {
            requests = { cpu = "10m", memory = "64Mi" }
            limits   = { memory = "256Mi" }
          }
          readiness_probe {
            exec {
              command = ["pg_isready", "-U", "postgres", "-h", "127.0.0.1"]
            }
            period_seconds = 10
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/postgresql/data"
          }
        }
      }
    }
    volume_claim_template {
      metadata {
        name = "data"
      }
      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = "local-path" # Retain: see 10-platform/storage.tf
        resources {
          requests = { storage = var.db_storage }
        }
      }
    }
  }
  depends_on = [kubernetes_manifest.secret]
}

resource "kubernetes_service_v1" "db" {
  metadata {
    name      = "db"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }
  spec {
    selector = local.db_labels
    port {
      port        = 5432
      target_port = 5432
    }
  }
}

# --- App ------------------------------------------------------------------------
resource "kubernetes_deployment_v1" "app" {
  metadata {
    name      = "app"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }
  spec {
    replicas = 1
    selector {
      match_labels = local.app_labels
    }
    template {
      metadata {
        labels = local.app_labels
      }
      spec {
        automount_service_account_token = false
        container {
          name  = "app"
          image = var.app_image
          env_from {
            secret_ref {
              name = "example-app"
            }
          }
          port {
            container_port = var.app_port
          }
          resources {
            requests = { cpu = "10m", memory = "128Mi" }
            limits   = { memory = "512Mi" }
          }
          security_context {
            allow_privilege_escalation = false
            capabilities { drop = ["ALL"] }
          }
          readiness_probe {
            tcp_socket {
              port = var.app_port
            }
            period_seconds = 10
          }
        }
      }
    }
  }
  depends_on = [kubernetes_manifest.secret]
}

# ClusterIP only; there is no LoadBalancer. A host-level edge proxy reaches this
# Service through its ClusterIP (set `cluster_ip` for a stable upstream address)
resource "kubernetes_service_v1" "app" {
  metadata {
    name      = "app"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }
  spec {
    selector = local.app_labels
    port {
      port        = var.app_port
      target_port = var.app_port
    }
  }
}

# --- NetworkPolicies --------------------------------------------------------------
# Default deny first; the allow rules below open only what is needed.
resource "kubernetes_network_policy_v1" "default_deny" {
  metadata {
    name      = "default-deny-ingress"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress"]
  }
}

# App: reachable only from the edge proxy CIDR, on the app port. Egress open.
resource "kubernetes_network_policy_v1" "app" {
  metadata {
    name      = "app"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }
  spec {
    pod_selector {
      match_labels = local.app_labels
    }
    policy_types = ["Ingress"]
    ingress {
      from {
        ip_block {
          cidr = var.edge_proxy_cidr
        }
      }
      ports {
        port     = tostring(var.app_port)
        protocol = "TCP"
      }
    }
  }
}

# Database: reachable only from the app pods.
resource "kubernetes_network_policy_v1" "db" {
  metadata {
    name      = "db"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }
  spec {
    pod_selector {
      match_labels = local.db_labels
    }
    policy_types = ["Ingress"]
    ingress {
      from {
        pod_selector {
          match_labels = local.app_labels
        }
      }
      ports {
        port     = "5432"
        protocol = "TCP"
      }
    }
  }
}
