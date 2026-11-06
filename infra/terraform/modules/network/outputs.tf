output "network_id" {
  value = google_compute_network.main.id
}

output "network_name" {
  value = google_compute_network.main.name
}

output "subnet_id" {
  value = google_compute_subnetwork.main.id
}

output "private_service_connection" {
  description = "Depend on this so Cloud SQL is not created before peering."
  value       = google_service_networking_connection.private_service_access.id
}

output "security_policy_id" {
  value = var.enable_cloud_armor ? google_compute_security_policy.edge[0].id : null
}
