variable "dev_account_id" {
  description = "AWS Account ID for the dev account"
  type        = string
}

variable "management_account_id" {
  description = "AWS Account ID for the management account"
  type        = string
}

variable "external_id" {
  description = "External ID for cross-account role assumption"
  type        = string
  sensitive   = true
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}
