terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  backend "s3" {
    bucket       = "acmecorp-terraform-state-272594899659"
    key          = "accounts/management/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region
}

# -------------------------------------------------------
# GitHub OIDC Identity Provider
# -------------------------------------------------------
# This registers GitHub as a trusted identity provider in AWS.
# When GitHub Actions runs, it gets a signed JWT token from GitHub.
# AWS verifies that token against this provider to confirm the
# request is genuinely coming from YOUR repository.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # This thumbprint is GitHub's TLS certificate fingerprint
  # AWS uses this to verify the OIDC tokens are really from GitHub
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = { ManagedBy = "Terraform" }
}

# -------------------------------------------------------
# GitHub Actions IAM Role
# -------------------------------------------------------
resource "aws_iam_role" "github_actions" {
  name        = "GitHubActionsRole"
  description = "Assumed by GitHub Actions via OIDC - no long-lived credentials"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringLike = {
          # Only YOUR repository can assume this role
          # Replace with your actual org/repo
          "token.actions.githubusercontent.com:sub" = "repo:Charleskojomark/acmecorp-landing-zone:*"
        }
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

# What GitHub Actions is allowed to do from the management account
resource "aws_iam_role_policy" "github_actions" {
  role = aws_iam_role.github_actions.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AssumeDeployRolesInWorkloadAccounts"
        Effect = "Allow"
        # Can assume the TerraformDeployRole in ANY account
        # Scoped down because TerraformDeployRole has its own external_id condition
        Action   = ["sts:AssumeRole"]
        Resource = "arn:aws:iam::*:role/TerraformDeployRole"
      },
      {
        Sid    = "ManageRemoteState"
        Effect = "Allow"
        Action = [
          "s3:GetObject", "s3:PutObject",
          "s3:DeleteObject", "s3:ListBucket",
          "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"
        ]
        Resource = [
          "arn:aws:s3:::acmecorp-terraform-state-${var.management_account_id}",
          "arn:aws:s3:::acmecorp-terraform-state-${var.management_account_id}/*",
          "arn:aws:dynamodb:${var.aws_region}:${var.management_account_id}:table/acmecorp-terraform-locks"
        ]
      }
    ]
  })
}

output "github_actions_role_arn" {
  value       = aws_iam_role.github_actions.arn
  description = "Paste this into the GitHub Actions workflow role-to-assume field"
}
