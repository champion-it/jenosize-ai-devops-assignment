# Infrastructure

Terraform for the Jenie Helpdesk AI platform on AWS.

## Layout

```
bootstrap/     state backend, ECR, GitHub OIDC, CI roles, budget
cluster/       VPC, EKS, RDS, Managed Prometheus, Argo Rollouts
envs/dev/      the dev namespace's Helm values
envs/prod/     the prod namespace's Helm values
modules/
  network/     VPC, subnets, NAT, flow logs
  eks/         cluster, Fargate profiles, OIDC provider, add-ons
  database/    RDS Postgres with pgvector, Secrets Manager
  irsa/        one IAM role bound to one service account
  observability/
```

Four roots rather than two, because they have genuinely different
lifecycles. Bootstrap is applied once by a human with broad permissions.
The cluster costs money by the hour from the moment it exists, so it is
applied deliberately. The environments are thin: they parameterise a Helm
release and are applied often.

## First run

Order matters, and the full sequence with a check after each phase is in
[`docs/deployment-checklist.md`](../../docs/deployment-checklist.md).

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars
terraform init && terraform apply
terraform output github_repository_variables   # set these in the repository

cd ../cluster
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config=backend.hcl
terraform apply                                 # 15 to 20 minutes

cd ../envs/dev
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config=backend.hcl
terraform apply
terraform output -raw helm_command              # run it
```

## State

An S3 bucket with versioning, encryption and all public access blocked,
locked by a DynamoDB table, one key per root.

The bucket is created by `bootstrap/`, not by the roots that use it. A
configuration that holds its own state bucket cannot be destroyed or
recreated cleanly, so bootstrap keeps its state locally and everything else
keeps theirs in the bucket it creates.

Recovery from corrupted state is restoring the previous object version.
Versioning is what makes that possible, which is why it is turned on in the
same resource that creates the bucket rather than left as a checklist item.

## Who owns what

The deploy pipeline owns the container image and, through Argo Rollouts, the
traffic split. Terraform owns everything else.

This boundary is why the environment roots do not deploy the chart
themselves: they render the values that depend on what the cluster created
and stop there. A `terraform apply` after a deploy cannot roll the running
version back, because Terraform never knew the version.

## Backups and disaster recovery

| Scenario | Control | Recovery |
| --- | --- | --- |
| Accidental data deletion | Automated backups with point in time recovery | Restore to a timestamp before the deletion. |
| Instance loss | Multi-AZ in prod, with automatic failover | Automatic, no manual action. |
| Region loss | Snapshots copied to a second region | Restore there and apply with the new region. Hours, which is the accepted trade against the cost of a hot standby. |
| Vector index corruption | The index is derived data, not source data | Rerun the indexer CronJob against `/data`. It is idempotent and rebuilds from scratch with `--force`. |
| Bad release | Argo Rollouts keeps the stable ReplicaSet | The canary aborts itself on an SLO breach and traffic returns to stable. Seconds, no rebuild. |
| Cluster loss | Nothing stateful lives in the cluster | Recreate it and reapply the chart. The database is untouched because it was never in there. |
| State corruption | S3 object versioning | Restore the previous version. |

Targets: prod RPO under 5 minutes and RTO under 1 hour; dev RPO 24 hours and
RTO best effort.

A restore procedure is only credible once it has been run. The intended
practice is a quarterly restore drill into a scratch instance with the
measured time recorded; it has not been run here, and saying so is more
useful than implying otherwise.

## Cost

This platform has a floor that does not scale to zero, and it is worth
being explicit about because it is the main trade against the previous
previous serverless design:

| | Monthly |
| --- | --- |
| EKS control plane | ~$73, charged whether or not a pod is scheduled |
| NAT gateway | ~$33 for one; multiply by the zone count for resilience |
| Load balancer | ~$16 |
| RDS `db.t4g.micro` | ~$12 |
| Fargate pods | ~$18 at this size |
| Managed Prometheus, ECR, Secrets Manager | ~$3 |

Roughly $155 a month with the cluster idle. `terraform destroy` on
`cluster/` stops all of it; `envs/` and the Helm release are cheap to leave.

Set `budget_alert_emails` in bootstrap so the alerts exist from the first
day rather than after the first invoice.
