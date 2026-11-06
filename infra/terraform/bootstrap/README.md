# Bootstrap

What has to exist before `envs/dev` or `envs/prod` can be applied. Run once,
by a human, from a workstation.

| Resource | Why it cannot live in an environment |
| --- | --- |
| Enabled APIs | An environment apply fails with "API not enabled" before it can enable anything. |
| State bucket | A configuration cannot keep its state in a bucket it is also creating. |
| Artifact Registry | The image paths in both environments and in CI point at it. |
| Workload Identity pool and provider | CI needs it to authenticate at all, including on the very first run. |
| CI service accounts | They are the identities the environments are applied *by*. |
| Billing budget | Project-wide, not per environment. |

This configuration keeps its state locally. That is deliberate and safe: it
is applied rarely, every resource in it is idempotent to recreate, and any of
them can be imported if the local state is lost.

## Permissions

The person running this needs `roles/owner` on the project, or at minimum
Project IAM Admin, Service Account Admin, Service Usage Admin, Storage Admin
and Artifact Registry Admin. The pipeline's own service account deliberately
never has these.

## Run it

```bash
cd infra/terraform/bootstrap

cp terraform.tfvars.example terraform.tfvars
# Fill in project_id, project_number, state_bucket_name, github_repository.
#   gcloud projects describe <project_id> --format='value(projectNumber)'
#   gcloud billing accounts list

gcloud auth application-default login
terraform init
terraform apply
```

Then publish the outputs as repository variables so the workflows can find
them. None of these is a secret; federation means there is no key to store.

```bash
terraform output -json github_repository_variables \
  | jq -r 'to_entries[] | "\(.key)=\(.value)"' \
  | while IFS='=' read -r k v; do gh variable set "$k" --body "$v"; done
```

Without the `gh` CLI, print them and paste them into
Settings -> Secrets and variables -> Actions -> Variables:

```bash
terraform output github_repository_variables
```

| Variable | Used by |
| --- | --- |
| `GCP_PROJECT_ID` | all three workflows |
| `GCP_REGION` | all three workflows |
| `GCP_WIF_PROVIDER` | all three workflows |
| `GCP_DEPLOY_SERVICE_ACCOUNT` | `ci.yml`, `deploy.yml` |
| `GCP_TERRAFORM_SERVICE_ACCOUNT` | `terraform.yml` |
| `GCP_TFSTATE_BUCKET` | `terraform.yml` |

## Then an image, then the environments

The order matters. `envs/dev` creates Cloud Run resources that reference an
image by tag, and Cloud Run rejects a deploy whose image does not exist, so
the first images are built and pushed before the first `terraform apply`, not
after it. From then on CI owns the tag, and the Cloud Run resources carry
`ignore_changes` on the image so a later apply will not roll it back.

```bash
gcloud auth configure-docker <region>-docker.pkg.dev --quiet

cd "$(git rev-parse --show-toplevel)"
docker buildx build --platform linux/amd64 \
  -f api/Dockerfile -t <registry>/api:bootstrap --push .
docker buildx build --platform linux/amd64 \
  -f worker/Dockerfile -t <registry>/worker:bootstrap --push .

cd infra/terraform/envs/dev
cp backend.hcl.example backend.hcl     # bucket = the state bucket above
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config=backend.hcl
terraform apply
```

`--platform linux/amd64` is required when building on an Apple Silicon Mac.
Cloud Run refuses an arm64 image, and the error names a manifest rather than
the architecture.

The full sequence, with a verification step after each phase, is in
[`docs/deployment-checklist.md`](../../../docs/deployment-checklist.md).

After that, infrastructure changes go through `.github/workflows/terraform.yml`
rather than from a workstation.

## Security notes

The federation provider is scoped with an attribute condition:

```hcl
attribute_condition = "assertion.repository == \"<owner>/<name>\""
```

Without it the provider trusts every repository on GitHub, and any workflow
anywhere could mint a token for this project. This is the single most
important line in the file.

The two CI identities are separate on purpose. `jenie-deploy` can push images
and manage Cloud Run and nothing else. `jenie-terraform` can change
infrastructure but is never used by a build. A compromise of the build
pipeline therefore cannot rewrite the network or the IAM policy.

`roles/editor` is avoided: it carries data access to Cloud SQL and Secret
Manager contents that neither account needs.

## Cost

`envs/prod` provisions regional Cloud SQL with a standby and keeps one Cloud
Run instance warm. That is a real monthly bill. For a demonstration, apply
`envs/dev` only - zonal database, Cloud Run scaling to zero - and leave the
prod configuration as the written statement of how it would be run.

Set `billing_account` so the budget and its alerts exist from the start.
