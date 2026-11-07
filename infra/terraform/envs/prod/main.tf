# Production environment.
#
# The cluster, the database instance and the metrics workspace are shared
# and belong to the cluster root. What is per-environment is the Helm
# release: this root holds the values that differ and the outputs the
# release needs, so the two are versioned together rather than one living
# in a wiki.
#
# Deliberately thin. An environment that only parameterises a chart should
# look like it.

data "terraform_remote_state" "cluster" {
  backend = "s3"
  config = {
    bucket = var.cluster_state.bucket
    key    = var.cluster_state.key
    region = var.cluster_state.region
  }
}

locals {
  environment = "prod"
  namespace   = "jenie-prod"
}

# The values the Helm release needs, rendered from what the cluster
# actually created rather than copied by hand into a values file.
resource "local_file" "helm_values" {
  filename        = "${path.module}/generated-values.yaml"
  file_permission = "0644"

  content = yamlencode({
    environment = local.environment

    namespace = {
      create = true
      name   = local.namespace
    }

    image = {
      registry = data.terraform_remote_state.cluster.outputs.ecr_registry
      api      = { tag = var.image_tag }
      worker   = { tag = var.image_tag }
    }

    serviceAccount = {
      create = true
      annotations = {
        "eks.amazonaws.com/role-arn" = data.terraform_remote_state.cluster.outputs.workload_role_arns["prod"]
      }
    }

    config = {
      logLevel = "INFO"
      # Traces go to the collector, which forwards to the tracing backend.
      otelEndpoint = "http://opentelemetry-collector.monitoring:4318"
    }

    # Progressive delivery, with the canary judged against the service
    # level indicators rather than a timer. The analysis queries the same
    # Managed Prometheus workspace the burn-rate alerts evaluate in, so a
    # release and an alert can never disagree about the error rate.
    rollout = {
      enabled = true
      trafficRouting = {
        alb = { enabled = true }
      }
      analysis = {
        enabled           = true
        prometheusAddress = data.terraform_remote_state.cluster.outputs.prometheus_query_base
      }
    }

    networkPolicy = {
      enabled      = true
      databaseCIDR = data.terraform_remote_state.cluster.outputs.vpc_cidr
    }
  })
}
