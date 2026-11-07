# Bootstrap

What has to exist before the cluster or either environment can be applied.
Run once, by a human, from a workstation.

| Resource | Why it cannot live elsewhere |
| --- | --- |
| S3 state bucket and lock table | A configuration cannot keep state in a bucket it is also creating. |
| ECR repositories | The image references in the chart and in CI point at them. |
| GitHub OIDC provider and CI roles | CI needs them to authenticate at all, including on its first run. |
| Budget | Account-wide, not per environment, and worth having before anything bills by the hour. |

This configuration keeps its state locally. That is deliberate and safe: it
is applied rarely, every resource in it is idempotent to recreate, and any
of them can be imported if the local state is lost.

## Permissions

The person running this needs enough to create IAM roles, an OIDC provider,
S3, DynamoDB, ECR and a budget. The CI roles it creates deliberately never
have that.

## Run it

```bash
cd infra/terraform/bootstrap

cp terraform.tfvars.example terraform.tfvars
# state_bucket_name must be globally unique across all of S3.
#   aws sts get-caller-identity --query Account --output text

terraform init
terraform apply
```

Then publish the outputs as repository variables. None is a secret: the
OIDC exchange means there is no key to store.

```bash
terraform output -json github_repository_variables \
  | jq -r 'to_entries[] | "\(.key)=\(.value)"' \
  | while IFS='=' read -r k v; do gh variable set "$k" --body "$v"; done
```

Without `gh`, print them and paste into
Settings -> Secrets and variables -> Actions -> Variables:

```bash
terraform output github_repository_variables
```

| Variable | Used by |
| --- | --- |
| `AWS_REGION` | all three workflows |
| `AWS_DEPLOY_ROLE_ARN` | `ci.yml`, `deploy.yml` |
| `AWS_TERRAFORM_ROLE_ARN` | `terraform.yml` |
| `TF_STATE_BUCKET`, `TF_STATE_LOCK_TABLE` | `terraform.yml` |
| `ECR_REGISTRY` | `ci.yml`, `deploy.yml` |
| `EKS_CLUSTER_NAME` | `deploy.yml` - comes from the cluster root, not from here |

## Security notes

The OIDC trust policy is pinned to one repository:

```hcl
condition {
  test     = "StringLike"
  variable = "token.actions.githubusercontent.com:sub"
  values   = ["repo:<owner>/<name>:*"]
}
```

Without it the provider trusts every repository on GitHub, and any workflow
anywhere could assume these roles. It is the single most important line in
the file. Renaming the repository without re-applying bootstrap breaks CI
authentication, which is the correct failure.

The two CI identities are separate on purpose. The deploy role can push
images and talk to the cluster; the terraform role can change
infrastructure. A compromise of the build pipeline therefore cannot rewrite
the network or the IAM policy.

The terraform role uses `PowerUserAccess` plus explicit IAM rather than
`AdministratorAccess`. That is narrower but still broad; a long-lived
account would replace it with an enumerated list once the resource set has
stopped changing, and pretending otherwise would be the wrong kind of
confidence.

## Cost

`monthly_budget_usd` defaults to 100 with alerts at 50, 80 and 100 percent
plus a forecast alert. On a platform whose control plane bills hourly, the
budget is not optional paperwork - it is the thing that tells you the
cluster is still running after you stopped looking at it.
