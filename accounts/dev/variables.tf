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

variable "bootstrap_role_name" {
  type        = string
  description = "The IAM role to assume in the workload account (defaults to the landing zone deploy role, can be overridden to OrganizationAccountAccessRole for initial bootstrap)"
  default     = "acmecorp-terraform-deploy"
}
