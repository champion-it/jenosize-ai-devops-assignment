# Cloud SQL for PostgreSQL with pgvector.
#
# One managed engine holds both the document metadata and the embeddings.
# That means one backup, one restore procedure and one private network path
# to secure, instead of running a separate vector database alongside.

resource "google_sql_database_instance" "main" {
  name             = "${var.name_prefix}-pg"
  database_version = "POSTGRES_16"
  region           = var.region

  # Guard against an accidental terraform destroy taking the data with it.
  deletion_protection = var.deletion_protection

  settings {
    tier              = var.tier
    availability_type = var.highly_available ? "REGIONAL" : "ZONAL"
    disk_type         = "PD_SSD"
    disk_size         = var.disk_size_gb
    disk_autoresize   = true

    backup_configuration {
      enabled    = true
      start_time = "17:00" # 00:00 ICT
      location   = var.backup_location

      # Point in time recovery is what turns a 24 hour RPO into minutes.
      point_in_time_recovery_enabled = var.point_in_time_recovery
      transaction_log_retention_days = var.point_in_time_recovery ? 7 : 1

      backup_retention_settings {
        retained_backups = var.retained_backups
        retention_unit   = "COUNT"
      }
    }

    ip_configuration {
      # No public IP. The instance is unreachable from the internet.
      ipv4_enabled                                  = false
      private_network                               = var.network_id
      enable_private_path_for_google_cloud_services = true
      ssl_mode                                      = "ENCRYPTED_ONLY"
    }

    database_flags {
      name  = "cloudsql.iam_authentication"
      value = "on"
    }

    database_flags {
      name  = "log_min_duration_statement"
      value = "1000"
    }

    insights_config {
      query_insights_enabled  = true
      record_application_tags = true
    }

    maintenance_window {
      day          = 7
      hour         = 18
      update_track = "stable"
    }
  }

  depends_on = [var.private_service_connection]
}

resource "google_sql_database" "app" {
  name     = var.database_name
  instance = google_sql_database_instance.main.name
}

resource "random_password" "app_user" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "google_sql_user" "app" {
  name     = var.database_user
  instance = google_sql_database_instance.main.name
  password = random_password.app_user.result
}

# The connection string exists only in Secret Manager. It is never written
# into an image, an environment file or the repository.
resource "google_secret_manager_secret" "database_url" {
  secret_id = "${var.name_prefix}-database-url"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "database_url" {
  secret = google_secret_manager_secret.database_url.id
  secret_data = format(
    "postgresql://%s:%s@%s:5432/%s",
    google_sql_user.app.name,
    urlencode(random_password.app_user.result),
    google_sql_database_instance.main.private_ip_address,
    google_sql_database.app.name,
  )
}
