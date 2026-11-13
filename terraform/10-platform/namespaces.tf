# Platform namespaces. The `platform.example.com/name` label is our own stable
# target for NetworkPolicy namespaceSelectors (kubernetes.io/metadata.name also
# exists, but this one is ours).
locals {
  platform_namespaces = ["monitoring", "backup", "sealed-secrets"]
}

resource "kubernetes_namespace_v1" "platform" {
  for_each = toset(local.platform_namespaces)

  metadata {
    name = each.key
    labels = {
      "platform.example.com/name"    = each.key
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}
