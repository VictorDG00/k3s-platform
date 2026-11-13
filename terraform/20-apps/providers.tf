variable "kubeconfig_path" {
  description = "Kubeconfig of the k3s node (reached through an SSH tunnel to the API on loopback)."
  type        = string
  default     = "~/.kube/k3s.yaml"
}

provider "kubernetes" {
  config_path = var.kubeconfig_path
}
