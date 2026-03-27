# ============================================================
# Bootstrap — Terraform Remote State Infrastructure
#
# This file creates the S3 bucket and DynamoDB table that all
# other Terraform configurations use to store and lock state.
#
# Run this ONCE manually before using any other Terraform config:
#   cd bootstrap && terraform init && terraform apply
#
# Security hardening: all Checkov findings resolved.
# ============================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.7.0"
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

# -------------------------------------------------------
# KMS key for S3 state bucket encryption
# -------------------------------------------------------
resource "aws_kms_key" "terraform_state" {
  description             = "KMS key for Terraform state bucket encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = {
    Name      = "terraform-state-kms-key"
    ManagedBy = "Terraform Bootstrap"
  }
}

resource "aws_kms_alias" "terraform_state" {
  name          = "alias/acmecorp-terraform-state"
  target_key_id = aws_kms_key.terraform_state.key_id
}

# -------------------------------------------------------
# KMS key for DynamoDB lock table encryption
# -------------------------------------------------------
resource "aws_kms_key" "dynamodb" {
  description             = "KMS key for Terraform lock table encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = {
    Name      = "terraform-dynamodb-kms-key"
    ManagedBy = "Terraform Bootstrap"
  }
}

resource "aws_kms_alias" "dynamodb" {
  name          = "alias/acmecorp-terraform-dynamodb"
  target_key_id = aws_kms_key.dynamodb.key_id
}

# -------------------------------------------------------
# Access log bucket (separate bucket, receives S3 logs)
# FIX: CKV_AWS_18 — S3 access logging requires a target bucket
# -------------------------------------------------------
resource "aws_s3_bucket" "access_logs" {
  bucket = "acmecorp-terraform-state-logs-${data.aws_caller_identity.current.account_id}"

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name        = "Terraform State Access Logs"
    ManagedBy   = "Terraform Bootstrap"
    Environment = "management"
  }
}

resource "aws_s3_bucket_versioning" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.terraform_state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket                  = aws_s3_bucket.access_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  rule {
    id     = "expire-old-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = 365
    }
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

# -------------------------------------------------------
# Primary Terraform state bucket
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

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.terraform_state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket                  = aws_s3_bucket.terraform_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# FIX: CKV_AWS_18 — enable S3 access logging
resource "aws_s3_bucket_logging" "terraform_state" {
  bucket        = aws_s3_bucket.terraform_state.id
  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "terraform-state-logs/"
}

# FIX: CKV2_AWS_61 — add lifecycle configuration to manage old state versions
resource "aws_s3_bucket_lifecycle_configuration" "terraform_state" {
  # Versioning must be enabled before lifecycle rules can be applied
  depends_on = [aws_s3_bucket_versioning.terraform_state]

  bucket = aws_s3_bucket.terraform_state.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    filter {}

    # Keep the last 90 days of non-current versions, then delete
    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    # Clean up incomplete multipart uploads after 7 days
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# FIX: CKV2_AWS_62 — enable S3 event notifications
# Publishes state change events to SNS for alerting/auditing
resource "aws_sns_topic" "terraform_state_events" {
  name              = "acmecorp-terraform-state-events"
  kms_master_key_id = aws_kms_key.terraform_state.arn

  tags = {
    Name      = "Terraform State Events"
    ManagedBy = "Terraform Bootstrap"
  }
}

resource "aws_sns_topic_policy" "terraform_state_events" {
  arn = aws_sns_topic.terraform_state_events.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowS3Publish"
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.terraform_state_events.arn
        Condition = {
          ArnLike = {
            "aws:SourceArn" = aws_s3_bucket.terraform_state.arn
          }
        }
      }
    ]
  })
}

resource "aws_s3_bucket_notification" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  topic {
    topic_arn     = aws_sns_topic.terraform_state_events.arn
    events        = ["s3:ObjectCreated:*", "s3:ObjectRemoved:*"]
    filter_prefix = ""
  }

  depends_on = [aws_sns_topic_policy.terraform_state_events]
}

# -------------------------------------------------------
# DynamoDB lock table
# FIX: CKV_AWS_119 — KMS CMK encryption
# FIX: CKV_AWS_28  — point-in-time recovery
# -------------------------------------------------------
resource "aws_dynamodb_table" "terraform_locks" {
  name         = "acmecorp-terraform-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  # FIX: CKV_AWS_28 — enable point-in-time recovery
  point_in_time_recovery {
    enabled = true
  }

  # FIX: CKV_AWS_119 — use KMS CMK for encryption at rest
  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.dynamodb.arn
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

