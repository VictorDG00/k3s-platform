variable "namespace" {
  type    = string
  default = "example-app"
}

variable "app_image" {
  description = "App image, pinned by tag AND digest."
  type        = string
}

variable "postgres_image" {
  description = "Postgres image, pinned by digest."
  type        = string
  default     = "docker.io/library/postgres:16-alpine@sha256:16bc17c64a573ef34162af9298258d1aec548232985b33ed7b1eac33ba35c229"
}

variable "edge_proxy_cidr" {
  description = "Source CIDR the edge reverse proxy connects from. Only this range may reach the app."
  type        = string
}

variable "app_port" {
  type    = number
  default = 8000
}

variable "db_storage" {
  type    = string
  default = "2Gi"
}
