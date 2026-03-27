# ============================================================
# Dev Account — Root Configuration
# ============================================================

terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

# This provider assumes a role INTO the dev account
# Every resource created here will be in the dev account
provider "aws" {
  region = var.aws_region
  assume_role {
    role_arn     = "arn:aws:iam::${var.dev_account_id}:role/${var.bootstrap_role_name}"
    external_id  = var.external_id
    session_name = "TerraformGitHubActions"
  }
}

# -------------------------------------------------------
# VPC
# -------------------------------------------------------
module "vpc" {
  source = "../../modules/vpc"

  name        = "acmecorp"
  environment = "dev"
  vpc_cidr    = "10.0.0.0/16"

  availability_zones   = ["us-east-1a", "us-east-1b", "us-east-1c"]
  public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  private_subnet_cidrs = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]

  # Cost optimization for dev — one NAT gateway instead of three
  enable_nat_gateway = true
  single_nat_gateway = true

  tags = { CostCenter = "engineering-dev" }
}

# -------------------------------------------------------
# IAM Roles
# -------------------------------------------------------
module "iam_roles" {
  source = "../../modules/iam-roles"

  management_account_id = var.management_account_id
  external_id           = var.external_id
  environment           = "dev"
}

# -------------------------------------------------------
# Outputs
# -------------------------------------------------------
output "vpc_id" { value = module.vpc.vpc_id }
output "private_subnet_ids" { value = module.vpc.private_subnet_ids }
output "public_subnet_ids" { value = module.vpc.public_subnet_ids }
output "nat_ips" { value = module.vpc.nat_gateway_public_ips }
