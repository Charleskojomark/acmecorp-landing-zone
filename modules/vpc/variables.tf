# ============================================================
# VPC Module — Input Variables
# All values are passed in when the module is called,
# making this module reusable across all environments
# ============================================================

variable "name" {
  description = "Base name for all resources (e.g., 'acmecorp')"
  type        = string
}

variable "environment" {
  description = "Environment name: dev, staging, prod, or shared"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod", "shared"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod, shared."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC (e.g., '10.0.0.0/16')"
  type        = string
}

variable "availability_zones" {
  description = "List of AZs to deploy subnets into (use at least 2 for high availability)"
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets — one per AZ"
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets — one per AZ"
  type        = list(string)
}

variable "enable_nat_gateway" {
  description = "Whether to create NAT Gateways (costs ~$32/month each — disable for dev to save money)"
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "Use one NAT Gateway instead of one per AZ. Cheaper but single point of failure."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
