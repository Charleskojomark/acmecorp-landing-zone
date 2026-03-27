terraform {
  backend "s3" {
    bucket       = "acmecorp-terraform-state-272594899659"
    key          = "accounts/prod/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
