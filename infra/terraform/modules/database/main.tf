# RDS PostgreSQL with pgvector.
#
# One instance holds the metadata and the embeddings, the same reasoning as
# before: one backup, one restore procedure, one network path to secure.
# pgvector ships with RDS PostgreSQL 15 and later as an available extension;
# the application creates it on first connection.

resource "aws_db_subnet_group" "main" {
  name       = "${var.name_prefix}-db"
  subnet_ids = var.subnet_ids
  tags       = var.tags
}

resource "aws_security_group" "database" {
  name        = "${var.name_prefix}-db"
  description = "Postgres, reachable only from inside the VPC"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name_prefix}-db" })
}

# Ingress is granted to specific security groups, never to a CIDR. A rule
# that names the cluster's group cannot accidentally widen when a subnet is
# resized.
resource "aws_vpc_security_group_ingress_rule" "postgres" {
  for_each = toset(var.allowed_security_group_ids)

  security_group_id            = aws_security_group.database.id
  referenced_security_group_id = each.value
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "Postgres from ${each.value}"
}

resource "random_password" "main" {
  length  = 32
  special = true
  # RDS rejects these in a master password.
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_db_instance" "main" {
  identifier     = "${var.name_prefix}-pg"
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.database_name
  username = var.database_user
  password = random_password.main.result
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.database.id]
  # No public endpoint. The database is reachable only from the VPC.
  publicly_accessible = false

  multi_az = var.multi_az

  backup_retention_period = var.backup_retention_days
  backup_window           = "17:00-18:00" # 00:00-01:00 ICT
  maintenance_window      = "sun:18:00-sun:19:00"
  copy_tags_to_snapshot   = true

  # Point in time recovery is what turns a 24 hour RPO into minutes. It is
  # implied by a backup retention period above zero, stated here for clarity.
  delete_automated_backups = false

  performance_insights_enabled    = var.performance_insights
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  auto_minor_version_upgrade = true
  apply_immediately          = var.apply_immediately

  deletion_protection = var.deletion_protection
  # A final snapshot on destroy is the right default for prod and pure
  # friction for a demo environment that is torn down daily.
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.name_prefix}-final-${formatdate("YYYYMMDDhhmmss", timestamp())}"

  tags = var.tags

  lifecycle {
    # The snapshot name embeds a timestamp, which would otherwise show as a
    # change on every plan.
    ignore_changes = [final_snapshot_identifier]
  }
}

# The connection string exists only in Secrets Manager. It is never written
# into a manifest, an image or the repository.
resource "aws_secretsmanager_secret" "database_url" {
  name                    = "${var.name_prefix}/database-url"
  description             = "Postgres connection string for ${var.name_prefix}"
  recovery_window_in_days = var.secret_recovery_days
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "database_url" {
  secret_id = aws_secretsmanager_secret.database_url.id
  secret_string = format(
    "postgresql://%s:%s@%s:%s/%s",
    aws_db_instance.main.username,
    urlencode(random_password.main.result),
    aws_db_instance.main.address,
    aws_db_instance.main.port,
    var.database_name,
  )
}
