output "terraform_deploy_role_arn" {
  value = aws_iam_role.terraform_deploy.arn
}

output "read_only_role_arn" {
  value = aws_iam_role.read_only.arn
}

output "developer_role_arn" {
  value = aws_iam_role.developer.arn
}
