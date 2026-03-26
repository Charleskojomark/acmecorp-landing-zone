# ============================================================
# BOOTSTRAP — Run this ONE TIME manually before anything else
# This creates the remote state backend that all other
# Terraform configurations will use.
# ============================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # NOTE: No backend block here — this is the ONLY Terraform config
  # that uses local state, because it's creating the remote state backend itself.
}

provider "aws" {
  region = var.aws_region
}

# Get the current account ID dynamically so we don't hardcode it
data "aws_caller_identity" "current" {}

# -------------------------------------------------------
# S3 Bucket — Terraform Remote State Storage
# -------------------------------------------------------
resource "aws_s3_bucket" "terraform_state" {
  # We include the account ID to make the bucket name globally unique
  bucket = "acmecorp-terraform-state-${data.aws_caller_identity.current.account_id}"

  # prevent_destroy means Terraform will REFUSE to delete this bucket
  # even if you run terraform destroy. This is a safety net.
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name        = "Terraform State Bucket"
    ManagedBy   = "Terraform Bootstrap"
    Environment = "management"
  }
}

# Enable versioning — every time state is updated, the old version is kept
# This means you can recover from a corrupted or accidentally deleted state file
resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Encrypt all state files at rest using AES-256
# State files can contain sensitive data like passwords, IPs, resource IDs
resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block ALL public access — state files should NEVER be publicly readable
resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket                  = aws_s3_bucket.terraform_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# -------------------------------------------------------
# DynamoDB Table — State Locking
# -------------------------------------------------------
# When Terraform runs, it writes a lock to this table.
# If another Terraform run starts at the same time, it sees
# the lock and waits. This prevents two people from running
# terraform apply simultaneously and corrupting the state file.
resource "aws_dynamodb_table" "terraform_locks" {
  name         = "acmecorp-terraform-locks"
  billing_mode = "PAY_PER_REQUEST"  # Only pay when locks are actually used
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"  # S = String type
  }

  tags = {
    Name      = "Terraform State Lock Table"
    ManagedBy = "Terraform Bootstrap"
  }
}

# -------------------------------------------------------
# IAM Role — For GitHub Actions to Access State
# -------------------------------------------------------
# GitHub Actions needs permission to read/write the state bucket
# and the lock table. We create a dedicated role for this.
resource "aws_iam_role" "terraform_state_role" {
  name = "TerraformStateRole"

  # This role can be assumed by any entity in the management account
  # In practice, this will be the GitHubActionsRole we create later
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "terraform_state_policy" {
  role = aws_iam_role.terraform_state_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3StateAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.terraform_state.arn,
          "${aws_s3_bucket.terraform_state.arn}/*"
        ]
      },
      {
        Sid    = "DynamoDBLockAccess"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem",
          "dynamodb:DescribeTable"
        ]
        Resource = aws_dynamodb_table.terraform_locks.arn
      }
    ]
  })
}

