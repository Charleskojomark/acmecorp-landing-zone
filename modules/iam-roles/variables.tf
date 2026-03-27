variable "management_account_id" {
  description = "Account ID of the management account that will assume roles here"
  type        = string
}

variable "external_id" {
  description = "External ID adds an extra layer of security to cross-account role assumption. Use a random UUID."
  type        = string
  sensitive   = true # Marks this as sensitive so it won't show in logs
}

variable "environment" {
  description = "Environment name for tagging"
  type        = string
}
