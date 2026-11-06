output "notification_channel_ids" {
  value = [for channel in google_monitoring_notification_channel.email : channel.id]
}

output "log_bucket_id" {
  value = google_logging_project_bucket_config.application.id
}
