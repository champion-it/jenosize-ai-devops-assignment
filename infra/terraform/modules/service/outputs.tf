output "api_url" {
  value = google_cloud_run_v2_service.api.uri
}

output "api_service_name" {
  value = google_cloud_run_v2_service.api.name
}

output "worker_job_name" {
  value = google_cloud_run_v2_job.worker.name
}

output "api_service_account" {
  value = google_service_account.api.email
}

output "worker_service_account" {
  value = google_service_account.worker.email
}
