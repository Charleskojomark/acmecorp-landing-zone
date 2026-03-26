# ============================================================
# IAM Roles Module
# Creates standard roles in each workload account that
# the management account (and GitHub Actions) can assume
# ============================================================

data "aws_caller_identity" "current" {}

# -------------------------------------------------------
# Terraform Deploy Role
# -------------------------------------------------------
# This is the role GitHub Actions assumes when it runs
# terraform apply in each account. It has admin access
# because Terraform needs to create/modify any resource.
# In a more mature setup, you'd replace AdministratorAccess
# with a custom least-privilege policy listing exactly
# what services Terraform is allowed to touch.
resource "aws_iam_role" "terraform_deploy" {
  name        = "TerraformDeployRole"
  description = "Assumed by GitHub Actions to deploy infrastructure via Terraform"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowManagementAccountAssumption"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.management_account_id}:root"
        }
        Action = "sts:AssumeRole"
        Condition = {
          # External ID prevents "confused deputy" attacks
          # where someone tricks your role into being assumed by wrong parties
          StringEquals = {
            "sts:ExternalId" = var.external_id
          }
        }
      }
    ]
  })

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Purpose     = "CI/CD Infrastructure Deployment"
  }
}

resource "aws_iam_role_policy_attachment" "terraform_deploy_admin" {
  role       = aws_iam_role.terraform_deploy.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# -------------------------------------------------------
# Read-Only Role
# -------------------------------------------------------
# For developers who need to see what's deployed
# but shouldn't be able to change anything
resource "aws_iam_role" "read_only" {
  name        = "ReadOnlyRole"
  description = "For developers and auditors to inspect infrastructure"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${var.management_account_id}:root" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Purpose     = "Read-only access for developers"
  }
}

resource "aws_iam_role_policy_attachment" "read_only" {
  role       = aws_iam_role.read_only.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# -------------------------------------------------------
# Developer Role
# -------------------------------------------------------
# For developers who need to deploy their own application
# code but shouldn't touch infrastructure
resource "aws_iam_role" "developer" {
  name        = "DeveloperRole"
  description = "For developers — can deploy apps but not change core infra"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${var.management_account_id}:root" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Custom developer policy — can do most things but can't touch
# sensitive infrastructure like VPCs, IAM, and Organizations
resource "aws_iam_role_policy" "developer" {
  role = aws_iam_role.developer.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowMostServices"
        Effect = "Allow"
        Action = [
          "ec2:Describe*",
          "ecs:*",
          "ecr:*",
          "eks:Describe*",
          "eks:List*",
          "lambda:*",
          "s3:*",
          "rds:Describe*",
          "cloudwatch:*",
          "logs:*",
          "ssm:*"
        ]
        Resource = "*"
      },
      {
        Sid    = "DenyDangerousActions"
        Effect = "Deny"
        Action = [
          "iam:*",
          "organizations:*",
          "ec2:DeleteVpc",
          "ec2:DeleteSubnet",
          "ec2:DeleteRouteTable",
          "ec2:DeleteInternetGateway",
          "ec2:DeleteNatGateway"
        ]
        Resource = "*"
      }
    ]
  })
}
