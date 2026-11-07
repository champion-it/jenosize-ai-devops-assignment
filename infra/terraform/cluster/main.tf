# The cluster, shared by both environments.
#
# One EKS cluster hosts dev and prod as separate namespaces. The assignment
# asks for "Separate environments: dev and prod (can be minimal)" and names
# k8s namespaces as the security baseline on this path.
#
# The trade, stated rather than hidden: one cluster means dev and prod share
# an upgrade window and a blast radius. Two clusters would isolate them and
# double a control plane that bills by the hour whether or not anything is
# scheduled. For a platform at this stage the shared cluster is the right
# point on that line; for one serving customers it would not be.
#
# It is a root of its own rather than part of envs/dev or envs/prod because
# it is shared infrastructure, like bootstrap, not per-environment
# infrastructure.

data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name_prefix = "jenie"

  namespaces = {
    dev  = "jenie-dev"
    prod = "jenie-prod"
  }

  # Argo Rollouts and the load balancer controller run on Fargate too, so
  # their namespaces need profiles or their pods never schedule.
  platform_namespaces = ["kube-system", "argo-rollouts"]
}

module "network" {
  source = "../modules/network"

  name_prefix        = local.name_prefix
  vpc_cidr           = var.vpc_cidr
  availability_zones = slice(data.aws_availability_zones.available.names, 0, 2)
  az_count           = 2

  # One gateway rather than one per zone. See the module for the trade.
  single_nat_gateway = var.single_nat_gateway
  tags               = var.tags
}

module "eks" {
  source = "../modules/eks"

  name               = "${local.name_prefix}-cluster"
  region             = var.region
  kubernetes_version = var.kubernetes_version

  private_subnet_ids = module.network.private_subnet_ids
  public_subnet_ids  = module.network.public_subnet_ids

  public_access_cidrs = var.cluster_public_access_cidrs
  fargate_namespaces  = concat(values(local.namespaces), local.platform_namespaces)

  tags = var.tags
}

module "database" {
  source = "../modules/database"

  name_prefix = local.name_prefix
  vpc_id      = module.network.vpc_id
  subnet_ids  = module.network.private_subnet_ids

  # Only the cluster may reach Postgres, named by security group rather
  # than by CIDR.
  allowed_security_group_ids = [module.eks.cluster_security_group_id]

  instance_class        = var.database_instance_class
  multi_az              = false
  backup_retention_days = 7
  deletion_protection   = false
  skip_final_snapshot   = true

  tags = var.tags
}

# One logical database per environment on the one instance. Two instances
# would isolate further and cost twice as much; a database each is the
# sensible middle ground.
resource "aws_secretsmanager_secret" "prod_database_url" {
  name                    = "${local.name_prefix}-prod/database-url"
  recovery_window_in_days = 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "prod_database_url" {
  secret_id = aws_secretsmanager_secret.prod_database_url.id
  # Same instance, different database. Creating the database itself is a
  # step in the cluster README: Terraform has no Postgres connection here,
  # and reaching into a private subnet to run SQL is not its job.
  secret_string = replace(
    data.aws_secretsmanager_secret_version.dev.secret_string,
    "/jenie$",
    "/jenie_prod",
  )
}

data "aws_secretsmanager_secret_version" "dev" {
  secret_id  = module.database.database_url_secret_arn
  depends_on = [module.database]
}

# ---------------------------------------------------------------------------
# Workload identity, one role per namespace
# ---------------------------------------------------------------------------

module "irsa_dev" {
  source = "../modules/irsa"

  role_name         = "${local.name_prefix}-dev-workload"
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  namespace         = local.namespaces.dev
  # Matches the service account the Helm chart creates:
  # <chart name>-<environment>.
  service_account = "jenie-helpdesk-ai-dev"
  secret_arns     = [module.database.database_url_secret_arn]

  # Writing metrics to Managed Prometheus is the only AWS API these pods
  # call beyond reading their own secret.
  inline_policies = {
    remote-write = data.aws_iam_policy_document.amp_write.json
  }

  tags = var.tags
}

module "irsa_prod" {
  source = "../modules/irsa"

  role_name         = "${local.name_prefix}-prod-workload"
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  namespace         = local.namespaces.prod
  service_account   = "jenie-helpdesk-ai-prod"
  secret_arns       = [aws_secretsmanager_secret.prod_database_url.arn]

  inline_policies = {
    remote-write = data.aws_iam_policy_document.amp_write.json
  }

  tags = var.tags
}

data "aws_iam_policy_document" "amp_write" {
  statement {
    effect    = "Allow"
    actions   = ["aps:RemoteWrite", "aps:GetSeries", "aps:GetLabels", "aps:GetMetricMetadata"]
    resources = [aws_prometheus_workspace.main.arn]
  }
}

data "aws_iam_policy_document" "amp_query" {
  statement {
    effect    = "Allow"
    actions   = ["aps:QueryMetrics", "aps:GetSeries", "aps:GetLabels", "aps:GetMetricMetadata"]
    resources = [aws_prometheus_workspace.main.arn]
  }
}

# Argo Rollouts queries Prometheus to decide whether a canary may proceed,
# so its controller needs read access and nothing else.
module "irsa_rollouts" {
  source = "../modules/irsa"

  role_name         = "${local.name_prefix}-argo-rollouts"
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  namespace         = "argo-rollouts"
  service_account   = "argo-rollouts"

  inline_policies = {
    query-metrics = data.aws_iam_policy_document.amp_query.json
  }

  tags = var.tags
}

module "irsa_lb_controller" {
  source = "../modules/irsa"

  role_name         = "${local.name_prefix}-lb-controller"
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  namespace         = "kube-system"
  service_account   = "aws-load-balancer-controller"

  inline_policies = {
    lb-controller = file("${path.module}/policies/lb-controller.json")
  }

  tags = var.tags
}
