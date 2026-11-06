output "api_url" {
  value = module.service.api_url
}

output "worker_job_name" {
  value = module.service.worker_job_name
}

output "database_instance" {
  value = module.database.instance_name
}
