variable "staging_account_id" {
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
  type    = string
  default = "us-east-1"
}