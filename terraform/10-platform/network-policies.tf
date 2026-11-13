# Default-deny ingress in `monitoring` and `backup` (enforced by the k3s
# kube-router network policy controller). Egress stays open (Alloy needs the
# API, Grafana downloads dashboards, the backup talks to object storage).
# Kubelet probes come from the node itself and are allowed by kube-router;
# `kubectl port-forward` enters through the pod's loopback.

resource "kubernetes_network_policy_v1" "default_deny" {
  for_each = toset(["monitoring", "backup"])

  metadata {
    name      = "default-deny-ingress"
    namespace = kubernetes_namespace_v1.platform[each.key].metadata[0].name
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress"]
  }
}

locals {
  # source (app.kubernetes.io/name label) -> destination selector -> port
  monitoring_allows = {
    "alloy-to-victoria-metrics"   = { from = "alloy", to = { "app" = "server", "app.kubernetes.io/name" = "victoria-metrics-single" }, port = 8428 }
    "grafana-to-victoria-metrics" = { from = "grafana", to = { "app" = "server", "app.kubernetes.io/name" = "victoria-metrics-single" }, port = 8428 }
    "alloy-to-loki"               = { from = "alloy", to = { "app.kubernetes.io/name" = "loki" }, port = 3100 }
    "grafana-to-loki"             = { from = "grafana", to = { "app.kubernetes.io/name" = "loki" }, port = 3100 }
    "alloy-to-kube-state-metrics" = { from = "alloy", to = { "app.kubernetes.io/name" = "kube-state-metrics" }, port = 8080 }
  }
}

resource "kubernetes_network_policy_v1" "monitoring_allow" {
  for_each = local.monitoring_allows

  metadata {
    name      = "allow-${each.key}"
    namespace = local.monitoring_ns
  }
  spec {
    pod_selector {
      match_labels = each.value.to
    }
    policy_types = ["Ingress"]
    ingress {
      from {
        pod_selector {
          match_labels = { "app.kubernetes.io/name" = each.value.from }
        }
      }
      ports {
        port     = each.value.port
        protocol = "TCP"
      }
    }
  }
}
