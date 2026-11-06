# Development environment.
#
# Same modules as prod, smaller and cheaper: single zone database, no
# point in time recovery, scale to zero. The shape of the system is
# identical so a change that works here behaves the same way in prod.

locals {
  environment = "dev"
  name_prefix = "jenie-dev"
}

module "network" {
  source = "../../modules/network"

  name_prefix = local.name_prefix
  region      = var.region
  subnet_cidr = "10.20.0.0/24"

  # Cloud Armor needs a load balancer in front of Cloud Run. Dev is reached
  # directly so the pipeline can smoke test it, and the application level
  # rate limiter is the control here.
  enable_cloud_armor = false
}

module "database" {
  source = "../../modules/database"

  name_prefix                = local.name_prefix
  region                     = var.region
  network_id                 = module.network.network_id
  private_service_connection = module.network.private_service_connection

  tier                   = "db-custom-1-3840"
  disk_size_gb           = 20
  highly_available       = false
  point_in_time_recovery = false
  retained_backups       = 7
  deletion_protection    = false
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

  min_instances         = 0
  max_instances         = 4
  memory                = "512Mi"
  log_level             = "DEBUG"
  rate_limit_per_minute = 120
  allow_unauthenticated = true
  reindex_schedule      = "0 3 * * *"
}

module "observability" {
  source = "../../modules/observability"

  project_id       = var.project_id
  environment      = local.environment
  region           = var.region
  api_service_name = module.service.api_service_name
  worker_job_name  = module.service.worker_job_name
  alert_emails     = var.alert_emails

  log_retention_days = 14
}
