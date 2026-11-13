# Remote state in an S3-compatible bucket (Cloudflare R2 style). Every value is
# a placeholder. Credentials come from the environment
# (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY), never from files in this repo.
terraform {
  backend "s3" {
    bucket = "example-tfstate"
    key    = "10-platform/terraform.tfstate"
    region = "auto"

    endpoints = {
      s3 = "https://<account>.r2.cloudflarestorage.com"
    }
    use_path_style = true

    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true

    # Native S3 locking (conditional writes, If-None-Match) instead of a
    # DynamoDB table. Requires a store that supports conditional PutObject.
    use_lockfile = true
  }
}
