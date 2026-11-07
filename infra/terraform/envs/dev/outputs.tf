output "namespace" {
  value = local.namespace
}

output "helm_values_file" {
  description = "Pass this to helm upgrade with -f. Generated from what the cluster created, so it cannot drift from reality."
  value       = local_file.helm_values.filename
}

output "helm_command" {
  value = join(" ", [
    "helm upgrade --install jenie ../../../k8s",
    "--namespace", local.namespace,
    "--create-namespace",
    "-f", "../../../k8s/values-dev.yaml",
    "-f", local_file.helm_values.filename,
  ])
}
