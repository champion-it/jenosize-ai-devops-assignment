output "instance_name" {
  value = google_sql_database_instance.main.name
}

output "connection_name" {
  value = google_sql_database_instance.main.connection_name
}

output "private_ip" {
  value = google_sql_database_instance.main.private_ip_address
}

output "database_url_secret_id" {
  value = google_secret_manager_secret.database_url.secret_id
}

output "database_url_secret_name" {
  value = google_secret_manager_secret.database_url.id
}
