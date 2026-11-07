output "instance_identifier" { value = aws_db_instance.main.identifier }
output "endpoint" { value = aws_db_instance.main.address }
output "port" { value = aws_db_instance.main.port }
output "security_group_id" { value = aws_security_group.database.id }

output "database_url_secret_arn" {
  value = aws_secretsmanager_secret.database_url.arn
}

output "database_url_secret_name" {
  value = aws_secretsmanager_secret.database_url.name
}
