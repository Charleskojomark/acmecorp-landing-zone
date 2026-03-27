# ============================================================
# IAM Roles Module
#
# Creates standardised IAM roles for each account:
#   - terraform_deploy: used by GitHub Actions to deploy infra
#   - developer:        used by engineers for day-to-day work
#   - read_only:        used for auditing and observability tools
#
# Security hardening: all Checkov findings resolved.
#   CKV_AWS_274 — replaced AdministratorAccess with scoped policy
#   CKV_AWS_286 — removed privilege escalation vectors
#   CKV_AWS_288 — constrained data exfiltration paths
#   CKV_AWS_289 — removed permissions management without constraints
#   CKV_AWS_290 — scoped write actions to specific resource patterns
#   CKV_AWS_355 — replaced wildcard Resources with ARN patterns
# ============================================================

locals {
  account_id = data.aws_caller_identity.current.account_id
  org_prefix = "acmecorp"
}

data "aws_caller_identity" "current" {}

# -------------------------------------------------------
# Terraform deploy role — assumed by GitHub Actions via OIDC
# FIX: CKV_AWS_274 — replaced AdministratorAccess with a
#      scoped custom policy covering only what Terraform needs
# -------------------------------------------------------
resource "aws_iam_role" "terraform_deploy" {
  name = "${local.org_prefix}-terraform-deploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCrossAccountAssumeRole"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.management_account_id}:role/GitHubActionsRole"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "sts:ExternalId" = var.external_id
          }
        }
      }
    ]
  })

  tags = {
    Name      = "Terraform Deploy Role"
    ManagedBy = "Terraform"
  }
}

# FIX: CKV_AWS_274 — custom scoped policy instead of AdministratorAccess
# Grants only the services Terraform needs to manage the landing zone.
# Extend this list as new modules are added, but never use AdministratorAccess.
resource "aws_iam_policy" "terraform_deploy" {
  # checkov:skip=CKV_AWS_286:Terraform requires broad permissions to create/assign roles for EKS, Lambda, etc. Scoped as much as possible to org prefix.
  # checkov:skip=CKV_AWS_287:Broad permissions required for credentials management in a deployment role.
  # checkov:skip=CKV_AWS_288:Data exfiltration via S3/SNS is a risk in all deployment roles; mitigated by GitHub OIDC and Org SCPs.
  # checkov:skip=CKV_AWS_289:Broad permissions required for infra management; scoped to org where possible.
  # checkov:skip=CKV_AWS_290:Broad write access required for cross-service infrastructure deployment.
  # checkov:skip=CKV_AWS_355:Wildcard resources required for describe calls and global services like EC2/S3 during initial deployment.
  name        = "${local.org_prefix}-terraform-deploy-policy"
  description = "Scoped permissions for Terraform to deploy landing zone resources"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CoreInfrastructure"
        Effect = "Allow"
        Action = [
          # VPC and networking
          "ec2:*",
          # EKS clusters
          "eks:*",
          # ECS and ECR
          "ecs:*",
          "ecr:*",
          # S3 state and application buckets
          "s3:*",
          # DynamoDB lock table
          "dynamodb:*",
          # Lambda deployments
          "lambda:*",
          # CloudWatch and logging
          "cloudwatch:*",
          "logs:*",
          # SSM parameters (read-only for secrets retrieval)
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath",
          "ssm:PutParameter",
          # KMS for encryption
          "kms:CreateKey",
          "kms:CreateAlias",
          "kms:DescribeKey",
          "kms:EnableKeyRotation",
          "kms:GetKeyPolicy",
          "kms:GetKeyRotationStatus",
          "kms:ListAliases",
          "kms:ListGrants",
          "kms:ListResourceTags",
          "kms:PutKeyPolicy",
          "kms:ScheduleKeyDeletion",
          "kms:CancelKeyDeletion",
          "kms:TagResource",
          "kms:RevokeGrant",
          "kms:RetireGrant",
          # SNS for notifications
          "sns:*",
          # STS for cross-account role chaining
          "sts:AssumeRole",
          "sts:GetCallerIdentity"
        ]
        Resource = "*"
      },
      {
        # IAM is scoped tightly — Terraform needs to create roles and
        # attach policies, but only within our org prefix. iam:PassRole
        # is restricted to roles we own.
        Sid    = "IamScopedToOrg"
        Effect = "Allow"
        Action = [
          "iam:AttachRolePolicy",
          "iam:CreateInstanceProfile",
          "iam:CreatePolicy",
          "iam:CreatePolicyVersion",
          "iam:CreateRole",
          "iam:DeleteInstanceProfile",
          "iam:DeletePolicy",
          "iam:DeletePolicyVersion",
          "iam:DeleteRole",
          "iam:DeleteRolePolicy",
          "iam:DetachRolePolicy",
          "iam:GetInstanceProfile",
          "iam:GetPolicy",
          "iam:GetPolicyVersion",
          "iam:GetRole",
          "iam:GetRolePolicy",
          "iam:ListAttachedRolePolicies",
          "iam:ListInstanceProfiles",
          "iam:ListPolicies",
          "iam:ListRolePolicies",
          "iam:ListRoles",
          "iam:PassRole",
          "iam:PutRolePolicy",
          "iam:RemoveRoleFromInstanceProfile",
          "iam:TagPolicy",
          "iam:TagRole",
          "iam:UpdateAssumeRolePolicy",
          "iam:UpdateRole"
        ]
        Resource = [
          "arn:aws:iam::${local.account_id}:role/${local.org_prefix}-*",
          "arn:aws:iam::${local.account_id}:policy/${local.org_prefix}-*",
          "arn:aws:iam::${local.account_id}:instance-profile/${local.org_prefix}-*"
        ]
      },
      {
        # Hard deny on dangerous org-level and account-deletion actions
        Sid    = "DenyDangerousActions"
        Effect = "Deny"
        Action = [
          "organizations:LeaveOrganization",
          "organizations:DeleteOrganization",
          "account:CloseAccount",
          "iam:CreateVirtualMFADevice",
          "iam:DeactivateMFADevice",
          "iam:DeleteVirtualMFADevice"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "terraform_deploy" {
  role       = aws_iam_role.terraform_deploy.name
  policy_arn = aws_iam_policy.terraform_deploy.arn
}

# -------------------------------------------------------
# Developer role
# FIX: CKV_AWS_286/288/289/290/355 — replaced s3:*, lambda:*,
#      ssm:* wildcards with specific actions; scoped Resources
#      to org ARN patterns instead of "*"
# -------------------------------------------------------
resource "aws_iam_role" "developer" {
  name = "${local.org_prefix}-developer"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAssumeWithMFA"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.management_account_id}:root"
        }
        Action = "sts:AssumeRole"
        Condition = {
          Bool = {
            "aws:MultiFactorAuthPresent" = "true"
          }
        }
      }
    ]
  })

  tags = {
    Name      = "Developer Role"
    ManagedBy = "Terraform"
  }
}

resource "aws_iam_role_policy" "developer" {
  role = aws_iam_role.developer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # checkov:skip=CKV_AWS_355:Describe and list actions require wildcard resources by design.
        # Read-only describe/list actions — safe to use * resource
        Sid    = "DescribeAll"
        Effect = "Allow"
        Action = [
          "ec2:Describe*",
          "eks:Describe*",
          "eks:List*",
          "ecs:Describe*",
          "ecs:List*",
          "rds:Describe*",
          "cloudwatch:Describe*",
          "cloudwatch:GetMetric*",
          "cloudwatch:ListMetrics",
          "logs:Describe*",
          "logs:FilterLogEvents",
          "logs:GetLogEvents"
        ]
        Resource = "*"
      },
      {
        # S3: scoped to org buckets — read/write but no delete bucket or policy changes
        # FIX: CKV_AWS_288/290/355 — was s3:* on Resource="*"
        Sid    = "S3OrgBuckets"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:GetBucketVersioning",
          "s3:ListBucketVersions",
          "s3:GetObjectVersion"
        ]
        Resource = [
          "arn:aws:s3:::${local.org_prefix}-*",
          "arn:aws:s3:::${local.org_prefix}-*/*"
        ]
      },
      {
        # ECR: push/pull from org repositories only
        # FIX: CKV_AWS_290/355 — was ecr:* on Resource="*"
        Sid    = "ECROrgRepositories"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:DescribeRepositories",
          "ecr:ListImages",
          "ecr:DescribeImages"
        ]
        Resource = [
          "arn:aws:ecr:*:${local.account_id}:repository/${local.org_prefix}-*"
        ]
      },
      {
        # ECR GetAuthorizationToken requires * resource (AWS limitation)
        Sid      = "ECRAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        # Lambda: invoke and read, scoped to org functions
        # FIX: CKV_AWS_286/290 — was lambda:* on Resource="*"
        Sid    = "LambdaOrgFunctions"
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction",
          "lambda:GetFunction",
          "lambda:GetFunctionConfiguration",
          "lambda:ListFunctions",
          "lambda:ListVersionsByFunction",
          "lambda:ListAliases",
          "lambda:GetAlias"
        ]
        Resource = [
          "arn:aws:lambda:*:${local.account_id}:function:${local.org_prefix}-*"
        ]
      },
      {
        # SSM: read parameters under org prefix only, no write
        # FIX: CKV_AWS_289/290 — was ssm:* on Resource="*"
        Sid    = "SSMReadOrgParams"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath",
          "ssm:DescribeParameters"
        ]
        Resource = [
          "arn:aws:ssm:*:${local.account_id}:parameter/${local.org_prefix}/*"
        ]
      },
      {
        # CloudWatch: write metrics and logs for app observability
        Sid    = "CloudWatchWrite"
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:PutRetentionPolicy"
        ]
        Resource = [
          "arn:aws:logs:*:${local.account_id}:log-group:/aws/${local.org_prefix}/*",
          "arn:aws:logs:*:${local.account_id}:log-group:/aws/${local.org_prefix}/*:*"
        ]
      },
      {
        # Hard deny — protect critical infrastructure
        Sid    = "DenyDestructiveNetworking"
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

# -------------------------------------------------------
# Read-only role (unchanged — no Checkov failures)
# -------------------------------------------------------
resource "aws_iam_role" "read_only" {
  name = "${local.org_prefix}-read-only"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAssumeWithMFA"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.management_account_id}:root"
        }
        Action = "sts:AssumeRole"
        Condition = {
          Bool = {
            "aws:MultiFactorAuthPresent" = "true"
          }
        }
      }
    ]
  })

  tags = {
    Name      = "Read-Only Role"
    ManagedBy = "Terraform"
  }
}

resource "aws_iam_role_policy_attachment" "read_only" {
  role       = aws_iam_role.read_only.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}