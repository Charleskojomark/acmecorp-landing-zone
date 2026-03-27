terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = var.aws_region
  assume_role {
    role_arn     = "arn:aws:iam::${var.prod_account_id}:role/TerraformDeployRole"
    external_id  = var.external_id
    session_name = "TerraformGitHubActions"
  }
}

module "vpc" {
  source = "../../modules/vpc"

  name        = "acmecorp"
  environment = "prod"
  vpc_cidr    = "10.2.0.0/16"

  availability_zones   = ["us-east-1a", "us-east-1b", "us-east-1c"]
  public_subnet_cidrs  = ["10.2.1.0/24", "10.2.2.0/24", "10.2.3.0/24"]
  private_subnet_cidrs = ["10.2.11.0/24", "10.2.12.0/24", "10.2.13.0/24"]

  # Full HA in prod — never compromise on availability here
  enable_nat_gateway = true
  single_nat_gateway = false

  tags = {
    CostCenter  = "engineering-prod"
    Criticality = "high"
    DataClass   = "confidential"
  }
}

module "iam_roles" {
  source = "../../modules/iam-roles"

  management_account_id = var.management_account_id
  external_id           = var.external_id
  environment           = "prod"
}

output "vpc_id" { value = module.vpc.vpc_id }
output "private_subnet_ids" { value = module.vpc.private_subnet_ids }
output "public_subnet_ids" { value = module.vpc.public_subnet_ids }
