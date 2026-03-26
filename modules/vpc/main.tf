# ============================================================
# VPC Module — Main Resources
# ============================================================

locals {
  # Merge common tags with any extra tags passed in
  common_tags = merge({
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = "AcmeCorp Landing Zone"
  }, var.tags)

  # How many NAT Gateways to create
  # If single_nat_gateway=true → 1 gateway, otherwise one per public subnet
  nat_gateway_count = var.enable_nat_gateway ? (
    var.single_nat_gateway ? 1 : length(var.public_subnet_cidrs)
  ) : 0
}

# -------------------------------------------------------
# VPC — The private network container
# -------------------------------------------------------
# Everything in AWS lives inside a VPC. It's your isolated
# slice of the AWS network, completely separate from other customers.
resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  # These two settings enable DNS within the VPC
  # Required for services like ECS, EKS, and RDS to resolve hostnames
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, {
    Name = "${var.name}-vpc-${var.environment}"
  })
}

# -------------------------------------------------------
# Internet Gateway — The VPC's door to the internet
# -------------------------------------------------------
# Without an IGW, nothing in the VPC can reach the internet.
# It's attached to the VPC and used by public subnets.
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.name}-igw-${var.environment}"
  })
}

# -------------------------------------------------------
# Public Subnets — For resources that need internet access
# -------------------------------------------------------
# We create one public subnet per Availability Zone.
# AZs are like different physical data centers in the same region.
# Spreading across AZs means if one data center has issues,
# your app keeps running in the other AZs.
resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  # Instances launched here automatically get a public IP
  # This is appropriate for load balancers and NAT gateways
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "${var.name}-public-subnet-${count.index + 1}-${var.environment}"
    Tier = "public"
    # These tags are required if you plan to use this VPC with Kubernetes (EKS)
    "kubernetes.io/role/elb" = "1"
  })
}

# -------------------------------------------------------
# Private Subnets — For resources that should NOT be
# directly reachable from the internet
# -------------------------------------------------------
# Your application servers, databases, and internal services
# live here. They can still reach the internet (for updates,
# API calls, etc.) via the NAT Gateway, but nothing from
# the internet can initiate a connection to them.
resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  # Private instances should NOT get public IPs
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name = "${var.name}-private-subnet-${count.index + 1}-${var.environment}"
    Tier = "private"
    # Required tag for EKS internal load balancers
    "kubernetes.io/role/internal-elb" = "1"
  })
}

# -------------------------------------------------------
# Elastic IPs for NAT Gateways
# -------------------------------------------------------
# NAT Gateways need static public IP addresses.
# Elastic IPs are static IPs that belong to your account.
resource "aws_eip" "nat" {
  count  = local.nat_gateway_count
  domain = "vpc"

  # EIPs must be created after the IGW
  depends_on = [aws_internet_gateway.main]

  tags = merge(local.common_tags, {
    Name = "${var.name}-nat-eip-${count.index + 1}-${var.environment}"
  })
}

# -------------------------------------------------------
# NAT Gateways — Allow private subnets to reach internet
# -------------------------------------------------------
# A NAT Gateway sits in a PUBLIC subnet and acts as a middleman.
# Private instances send outbound traffic → NAT Gateway → Internet.
# Return traffic comes back to NAT Gateway → private instance.
# The internet only ever sees the NAT Gateway's IP, not the private instance.
resource "aws_nat_gateway" "main" {
  count = local.nat_gateway_count

  allocation_id = aws_eip.nat[count.index].id
  # NAT Gateways MUST live in public subnets
  subnet_id     = aws_subnet.public[count.index].id

  depends_on = [aws_internet_gateway.main]

  tags = merge(local.common_tags, {
    Name = "${var.name}-nat-gw-${count.index + 1}-${var.environment}"
  })
}

# -------------------------------------------------------
# Route Tables — Traffic direction rules
# -------------------------------------------------------
# A route table is like a routing table for a network switch.
# It tells AWS: "if traffic is going to X, send it via Y"

# Public route table: send internet-bound traffic to the IGW
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"                # "all traffic"
    gateway_id = aws_internet_gateway.main.id  # goes via the internet gateway
  }

  tags = merge(local.common_tags, {
    Name = "${var.name}-public-rt-${var.environment}"
  })
}

# Private route tables: one per AZ (or one total if single_nat_gateway)
# Send internet-bound traffic from private subnets via the NAT Gateway
resource "aws_route_table" "private" {
  count  = length(var.private_subnet_cidrs)
  vpc_id = aws_vpc.main.id

  dynamic "route" {
    for_each = var.enable_nat_gateway ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      # If single NAT gateway, always use index 0; otherwise use matching AZ's NAT
      nat_gateway_id = var.single_nat_gateway ? aws_nat_gateway.main[0].id : aws_nat_gateway.main[count.index].id
    }
  }

  tags = merge(local.common_tags, {
    Name = "${var.name}-private-rt-${count.index + 1}-${var.environment}"
  })
}

# Associate public subnets with the public route table
resource "aws_route_table_association" "public" {
  count          = length(var.public_subnet_cidrs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Associate each private subnet with its private route table
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
  vpc_endpoint_type = "Gateway"  # Gateway type is free

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
