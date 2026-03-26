# ============================================================
# Variables for Bootstrap Terraform
# ============================================================

variable "aws_region" {
  description = "AWS region where bootstrap resources will be created"
  type        = string
  default     = "us-east-1"
}