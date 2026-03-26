output "state_bucket_name" {
  description = "Name of the S3 bucket storing Terraform state — copy this for use in all backend.tf files"
  value       = aws_s3_bucket.terraform_state.bucket
}

output "state_bucket_arn" {
  description = "ARN of the state bucket"
  value       = aws_s3_bucket.terraform_state.arn
}

output "dynamodb_table_name" {
  description = "Name of the DynamoDB lock table"
  value       = aws_dynamodb_table.terraform_locks.name
}

output "terraform_state_role_arn" {
  description = "ARN of the role that can access state — use in all backend.tf role_arn fields"
  value       = aws_iam_role.terraform_state_role.arn
}
