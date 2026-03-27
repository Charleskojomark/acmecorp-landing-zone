variable "prod_account_id" {
  type = string
}

variable "management_account_id" {
  type = string
}

variable "external_id" {
  type      = string
  sensitive = true
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
