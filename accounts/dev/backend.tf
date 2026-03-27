# ============================================================
# Backend Configuration — Dev Account
# Tells Terraform where to store this account's state file
# IMPORTANT: Replace <MGMT_ACCOUNT_ID> with your actual management account ID
# ============================================================
terraform {
  backend "s3" {
    bucket       = "acmecorp-terraform-state-272594899659"
    key          = "accounts/dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
