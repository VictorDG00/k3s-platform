# Monitoring stack. Everything is ClusterIP: operator access is through
# `kubectl port-forward` (e.g. kubectl -n monitoring port-forward svc/grafana 3000:80).
#
# Each chart version is pinned here, and each image is pinned by tag + digest in
# values/*.yaml.

locals {
  monitoring_ns = kubernetes_namespace_v1.platform["monitoring"].metadata[0].name
}

resource "helm_release" "victoria_metrics" {
  name       = "victoria-metrics"
  namespace  = local.monitoring_ns
  repository = "https://victoriametrics.github.io/helm-charts"
  chart      = "victoria-metrics-single"
  version    = "0.48.0" # app v1.153.0

  atomic          = true
  cleanup_on_fail = true
  timeout         = 600

  values     = [file("${path.module}/values/victoria-metrics.yaml")]
  depends_on = [kubernetes_manifest.storage_class]
}

resource "helm_release" "loki" {
  name       = "loki"
  namespace  = local.monitoring_ns
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  version    = "7.3.0" # app 3.6.12

  atomic          = true
  cleanup_on_fail = true
  timeout         = 600

  values     = [file("${path.module}/values/loki.yaml")]
  depends_on = [kubernetes_manifest.storage_class]
}

resource "helm_release" "kube_state_metrics" {
  name       = "kube-state-metrics"
  namespace  = local.monitoring_ns
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-state-metrics"
  version    = "8.6.0" # app v2.20.0

  atomic          = true
  cleanup_on_fail = true
  timeout         = 300

  values = [file("${path.module}/values/kube-state-metrics.yaml")]
}

resource "helm_release" "grafana" {
  name       = "grafana"
  namespace  = local.monitoring_ns
  repository = "https://grafana.github.io/helm-charts"
  chart      = "grafana"
  version    = "10.5.14" # app 12.3.1

  atomic          = true
  cleanup_on_fail = true
  timeout         = 600

  values     = [file("${path.module}/values/grafana.yaml")]
  depends_on = [kubernetes_manifest.storage_class, helm_release.victoria_metrics, helm_release.loki]
}

resource "helm_release" "alloy" {
  name       = "alloy"
  namespace  = local.monitoring_ns
  repository = "https://grafana.github.io/helm-charts"
  chart      = "alloy"
  version    = "1.13.1" # app v1.20.1

  atomic          = true
  cleanup_on_fail = true
  timeout         = 600

  values = [
    file("${path.module}/values/alloy.yaml"),
    yamlencode({ alloy = { configMap = { content = file("${path.module}/files/alloy.alloy") } } }),
  ]
  depends_on = [helm_release.victoria_metrics, helm_release.loki, helm_release.kube_state_metrics]
}
