# Development environment.
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
  environment = "dev"
  namespace   = "jenie-dev"
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
        "eks.amazonaws.com/role-arn" = data.terraform_remote_state.cluster.outputs.workload_role_arns["dev"]
      }
    }

    config = {
      # Dev traces everything and talks more.
      logLevel     = "DEBUG"
      otelEndpoint = ""
    }

    # Dev keeps the Deployment: progressive delivery is a production
    # concern, and a canary on one replica measures nothing.
    rollout = {
      enabled = false
    }

    networkPolicy = {
      enabled      = true
      databaseCIDR = data.terraform_remote_state.cluster.outputs.vpc_cidr
    }
  })
}
