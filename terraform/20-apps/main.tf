# One module per app. `example-app` shows the pattern: namespace, sealed
# secrets, Postgres StatefulSet, app Deployment, Service, NetworkPolicies.
module "example_app" {
  source = "./example-app"

  edge_proxy_cidr = "192.0.2.0/24" # placeholder: CIDR your edge proxy connects from
  app_image       = "registry.example.com/example/app:1.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000"
}
