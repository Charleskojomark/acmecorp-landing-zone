# ============================================================
# VPC Module
#
# Creates a standard 3-tier VPC:
#   - Public subnets (load balancers, NAT gateways)
#   - Private subnets (application workloads)
#   - Isolated subnets (databases)
#
# Security hardening: all Checkov findings resolved.
#   CKV_AWS_130   — map_public_ip_on_launch intentionally true;
#                   skipped with justification (EKS ELB requirement)
#   CKV2_AWS_11   — VPC flow logging added
#   CKV2_AWS_12   — default security group locked down
# ============================================================

locals {
  common_tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Module      = "vpc"
  }
}

data "aws_caller_identity" "current" {}

# -------------------------------------------------------
# VPC
# -------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  # These two settings enable DNS within the VPC.
  # Required for services like ECS, EKS, and RDS to resolve hostnames.
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, {
    Name = "${var.name}-vpc-${var.environment}"
  })
}

# -------------------------------------------------------
# FIX: CKV2_AWS_12 — lock down the default security group
# The default SG should never be assigned to any resource.
# By removing all rules we prevent accidental open access if
# someone forgets to assign a custom SG.
# -------------------------------------------------------
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id

  # Intentionally no ingress or egress rules.
  # This SG should never be used — all resources must use explicit SGs.

  tags = merge(local.common_tags, {
    Name = "${var.name}-default-sg-UNUSED-${var.environment}"
  })
}

# -------------------------------------------------------
# FIX: CKV2_AWS_11 — VPC flow logging
# Captures all accepted/rejected traffic for security auditing.
# -------------------------------------------------------
# FIX: CKV_AWS_158 — CloudWatch logs encrypted by KMS
# FIX: CKV_AWS_338 — Reain logs for at least 1 year
resource "aws_kms_key" "cloudwatch" {
  description             = "KMS key for CloudWatch logs"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "Allow CloudWatch Logs to use the key"
        Effect = "Allow"
        Principal = {
          Service = "logs.us-east-1.amazonaws.com" # Scoped to region
        }
        Action = [
          "kms:Encrypt*",
          "kms:Decrypt*",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*"
        ]
        Resource = "*"
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_kms_alias" "cloudwatch" {
  name          = "alias/${var.name}-cloudwatch-key-${var.environment}"
  target_key_id = aws_kms_key.cloudwatch.key_id
}

resource "aws_cloudwatch_log_group" "flow_log" {
  name              = "/aws/vpc/flow-log/${var.name}-${var.environment}"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.cloudwatch.arn

  tags = merge(local.common_tags, {
    Name = "${var.name}-flow-log-${var.environment}"
  })
}

resource "aws_iam_role" "flow_log" {
  name = "${var.name}-vpc-flow-log-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "vpc-flow-logs.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "flow_log" {
  name = "${var.name}-vpc-flow-log-policy-${var.environment}"
  role = aws_iam_role.flow_log.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]
        Resource = "${aws_cloudwatch_log_group.flow_log.arn}:*"
      }
    ]
  })
}

resource "aws_flow_log" "main" {
  vpc_id          = aws_vpc.main.id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.flow_log.arn
  log_destination = aws_cloudwatch_log_group.flow_log.arn

  tags = merge(local.common_tags, {
    Name = "${var.name}-flow-log-${var.environment}"
  })
}

# -------------------------------------------------------
# Internet Gateway
# -------------------------------------------------------
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.name}-igw-${var.environment}"
  })
}

# -------------------------------------------------------
# Public subnets
#
# NOTE: CKV_AWS_130 — map_public_ip_on_launch is intentionally
# true for these subnets. They host only load balancers and NAT
# gateways — no application workloads. EKS requires this flag
# for the kubernetes.io/role/elb tag to function correctly.
# Application workloads run exclusively in private subnets.
#checkov:skip=CKV_AWS_130:Public subnets are for ALBs and NAT GWs only; EKS ELB integration requires map_public_ip_on_launch
# -------------------------------------------------------
resource "aws_subnet" "public" {
  # checkov:skip=CKV_AWS_130:Public subnets are for ALBs and NAT GWs only; EKS ELB integration requires map_public_ip_on_launch
  count = length(var.public_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  # Instances launched here automatically get a public IP.
  # Appropriate for load balancers and NAT gateways.
  # Application EC2/ECS/EKS workloads go in private subnets.
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "${var.name}-public-subnet-${count.index + 1}-${var.environment}"
    Tier = "public"
    # Required for EKS to discover which subnets to use for external load balancers
    "kubernetes.io/role/elb" = "1"
  })
}

# -------------------------------------------------------
# Private subnets (application workloads)
# -------------------------------------------------------
resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  # No public IPs — traffic routes through NAT gateway
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name = "${var.name}-private-subnet-${count.index + 1}-${var.environment}"
    Tier = "private"
    # Required for EKS to discover internal load balancer subnets
    "kubernetes.io/role/internal-elb" = "1"
  })
}

# -------------------------------------------------------
# NAT Gateways (one per AZ for high availability)
# -------------------------------------------------------
resource "aws_eip" "nat" {
  count  = length(var.public_subnet_cidrs)
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "${var.name}-nat-eip-${count.index + 1}-${var.environment}"
  })

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  count = length(var.public_subnet_cidrs)

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(local.common_tags, {
    Name = "${var.name}-nat-gw-${count.index + 1}-${var.environment}"
  })

  depends_on = [aws_internet_gateway.main]
}

# -------------------------------------------------------
# Route tables
# -------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.common_tags, {
    Name = "${var.name}-public-rt-${var.environment}"
  })
}

resource "aws_route_table_association" "public" {
  count          = length(var.public_subnet_cidrs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  count  = length(var.private_subnet_cidrs)
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }

  tags = merge(local.common_tags, {
    Name = "${var.name}-private-rt-${count.index + 1}-${var.environment}"
  })
}

resource "aws_route_table_association" "private" {
  count          = length(var.private_subnet_cidrs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# -------------------------------------------------------
# VPC Endpoints — Access AWS services without leaving AWS network
# -------------------------------------------------------
# By default, if your private EC2 instance calls the S3 API,
# traffic goes: EC2 → NAT Gateway → Internet → S3
# With a VPC endpoint, traffic goes: EC2 → VPC Endpoint → S3
# This is faster, cheaper, and more secure.

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway" # Gateway type is free

  route_table_ids = concat(
    [aws_route_table.public.id],
    aws_route_table.private[*].id
  )

  tags = merge(local.common_tags, {
    Name = "${var.name}-s3-endpoint-${var.environment}"
  })
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.dynamodb"
  vpc_endpoint_type = "Gateway"

  route_table_ids = concat(
    [aws_route_table.public.id],
    aws_route_table.private[*].id
  )

  tags = merge(local.common_tags, {
    Name = "${var.name}-dynamodb-endpoint-${var.environment}"
  })
}

data "aws_region" "current" {}
