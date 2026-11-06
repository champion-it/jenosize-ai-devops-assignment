# Production environment.
#
# Differences from dev, all of them deliberate:
#   - regional database with automatic failover and point in time recovery
#   - one warm instance so the first request of the day is not a cold start
#   - Cloud Armor in front of the service
#   - longer log retention for audit
#   - deletion protection on the database

locals {
  environment = "prod"
  name_prefix = "jenie-prod"
}

module "network" {
  source = "../../modules/network"

  name_prefix = local.name_prefix
  region      = var.region
  subnet_cidr = "10.30.0.0/24"

  enable_cloud_armor    = true
  rate_limit_per_minute = 300
}

module "database" {
  source = "../../modules/database"

  name_prefix                = local.name_prefix
  region                     = var.region
  network_id                 = module.network.network_id
  private_service_connection = module.network.private_service_connection

  tier                   = "db-custom-2-7680"
  disk_size_gb           = 50
  highly_available       = true
  point_in_time_recovery = true
  retained_backups       = 30
  backup_location        = "asia"
  deletion_protection    = true
}

module "service" {
  source = "../../modules/service"

  project_id   = var.project_id
  name_prefix  = local.name_prefix
  environment  = local.environment
  region       = var.region
  network_name = module.network.network_name
  subnet_name  = module.network.subnet_id

  api_image    = var.api_image
  worker_image = var.worker_image

  database_url_secret_id   = module.database.database_url_secret_id
  database_url_secret_name = module.database.database_url_secret_name

  min_instances         = 1
  max_instances         = 20
  memory                = "1Gi"
  cpu                   = "2"
  log_level             = "INFO"
  rate_limit_per_minute = 60
  allow_unauthenticated = true
  reindex_schedule      = "0 2 * * *"
}

module "observability" {
  source = "../../modules/observability"

  project_id       = var.project_id
  environment      = local.environment
  region           = var.region
  api_service_name = module.service.api_service_name
  worker_job_name  = module.service.worker_job_name
  alert_emails     = var.alert_emails

  error_rate_threshold = 0.2
  latency_threshold_ms = 2000
  log_retention_days   = 90
}
