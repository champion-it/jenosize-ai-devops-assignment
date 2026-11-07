output "cluster_name" {
  value = module.eks.cluster_name
}

output "update_kubeconfig" {
  description = "Run this, then helm upgrade --install."
  value       = module.eks.update_kubeconfig_command
}

output "workload_role_arns" {
  description = "Put each on the chart's serviceAccount.annotations as eks.amazonaws.com/role-arn."
  value = {
    dev  = module.irsa_dev.role_arn
    prod = module.irsa_prod.role_arn
  }
}

output "prometheus_workspace_id" {
  value = aws_prometheus_workspace.main.id
}

output "prometheus_remote_write_url" {
  description = "The chart's metrics sidecar writes here; Argo Rollouts queries it."
  value       = "${aws_prometheus_workspace.main.prometheus_endpoint}api/v1/remote_write"
}

output "prometheus_query_url" {
  value = "${aws_prometheus_workspace.main.prometheus_endpoint}api/v1/query"
}

output "database_endpoint" {
  value = module.database.endpoint
}

output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "vpc_cidr" {
  value = module.network.vpc_cidr
}

output "ecr_registry" {
  description = "Registry host. The repositories themselves are created by bootstrap."
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com/jenie"
}

output "prometheus_query_base" {
  description = "What Argo Rollouts points its analysis provider at."
  value       = trimsuffix(aws_prometheus_workspace.main.prometheus_endpoint, "/")
}
