output "role_arn" {
  description = "Put this on the service account as eks.amazonaws.com/role-arn."
  value       = aws_iam_role.main.arn
}

output "role_name" {
  value = aws_iam_role.main.name
}
