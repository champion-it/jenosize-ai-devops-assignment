# Deployment checklist

From an empty Google Cloud project to a running service, in order. Each phase
ends with a check that proves it worked, so a failure is caught where it
happened rather than three steps later.

Set these once and reuse them in the commands below.

```bash
export PROJECT_ID="jenosize-jenie"          # your project
export REGION="asia-southeast1"             # Singapore, closest to Thailand
export REPO="champion-it/jenosize-ai-devops-assignment"
export REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/jenie"
```

---

## Phase 0 - Prerequisites

- [ ] `gcloud` installed and logged in

      gcloud auth login
      gcloud config set project "$PROJECT_ID"

- [ ] Application default credentials for Terraform

      gcloud auth application-default login

- [ ] Billing is enabled on the project

      gcloud billing projects describe "$PROJECT_ID"

- [ ] `terraform` >= 1.9, `docker`, and optionally `gh`

**Check:** `gcloud config get-value project` prints your project id.

---

## Phase 1 - Bootstrap

Creates the things the environments depend on but cannot create: enabled
APIs, the state bucket, the image registry, the GitHub federation and the two
CI service accounts.

- [ ] Collect the project number and billing account

      gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)'
      gcloud billing accounts list

- [ ] Fill in the variables

      cd infra/terraform/bootstrap
      cp terraform.tfvars.example terraform.tfvars
      # project_id, project_number, region, state_bucket_name, github_repository
      # state_bucket_name must be globally unique: <project_id>-tfstate works.

- [ ] Apply

      terraform init
      terraform apply

**Check:** all four exist.

```bash
gcloud artifacts repositories describe jenie --location="$REGION"
gcloud iam workload-identity-pools describe github-pool --location=global
gcloud storage buckets describe "gs://${PROJECT_ID}-tfstate"
gcloud iam service-accounts list --filter='email ~ jenie-'
```

> The federation provider is restricted to one repository by an attribute
> condition. If you forked or renamed the repository, change
> `github_repository` and re-apply, or CI will be refused a token.

---

## Phase 2 - Build and push the first images

`envs/dev` creates Cloud Run resources that reference an image by tag, and
Cloud Run rejects a deploy whose image does not exist. So images come before
the first `terraform apply`, not after. From then on CI owns them.

- [ ] Authenticate Docker against Artifact Registry

      gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet

- [ ] Build and push both images

      cd "$(git rev-parse --show-toplevel)"
      docker buildx build --platform linux/amd64 \
        -f api/Dockerfile -t "${REGISTRY}/api:bootstrap" --push .
      docker buildx build --platform linux/amd64 \
        -f worker/Dockerfile -t "${REGISTRY}/worker:bootstrap" --push .

> `--platform linux/amd64` is not optional on an Apple Silicon Mac. Without
> it Docker builds arm64, Cloud Run refuses the image, and the error names a
> manifest rather than the architecture, which is a slow thing to debug.

**Check:** both tags are listed.

```bash
gcloud artifacts docker images list "$REGISTRY" --include-tags
```

---

## Phase 3 - Apply the dev environment

- [ ] Point at the state bucket

      cd infra/terraform/envs/dev
      cp backend.hcl.example backend.hcl
      # bucket = "<project_id>-tfstate"

- [ ] Set the variables

      cp terraform.tfvars.example terraform.tfvars
      # project_id, region,
      # api_image    = "<REGISTRY>/api:bootstrap"
      # worker_image = "<REGISTRY>/worker:bootstrap"
      # alert_emails = ["you@example.com"]

- [ ] Apply

      terraform init -backend-config=backend.hcl
      terraform plan        # read it before applying
      terraform apply

Cloud SQL takes roughly 10 to 15 minutes to create. That is normal.

**Check:** the service answers.

```bash
API_URL=$(terraform output -raw api_url)
curl -fsS "$API_URL/healthz"    # {"status":"ok"}
curl -fsS "$API_URL/readyz"     # {"status":"ready"}
```

A failing `/readyz` with a healthy `/healthz` means the database is not
reachable: check that the private service connection finished and that the
`DATABASE_URL` secret resolved.

---

## Phase 4 - Index the knowledge base

- [ ] Run the indexer job once

      gcloud run jobs execute jenie-dev-worker --region "$REGION" --wait

**Check:** retrieval returns sources.

```bash
curl -fsS "$API_URL/ask" -H 'content-type: application/json' \
  -d '{"query":"How do I reset my password?"}'
```

Empty `sources` means the index is empty. Check the job's logs:

```bash
gcloud run jobs executions list --job jenie-dev-worker --region "$REGION"
```

---

## Phase 5 - Hand over to CI/CD

Up to here everything was applied by hand. From now on the repository is the
source of truth and nothing is applied from a workstation.

- [ ] Publish the repository variables

      cd infra/terraform/bootstrap
      terraform output -json github_repository_variables \
        | jq -r 'to_entries[] | "\(.key)=\(.value)"' \
        | while IFS='=' read -r k v; do gh variable set "$k" --body "$v" --repo "$REPO"; done

      # Without gh: print them and paste into
      # Settings -> Secrets and variables -> Actions -> Variables
      terraform output github_repository_variables

  Six variables, no secrets. Federation means there is no key to store.

- [ ] Create the GitHub Environments

      Settings -> Environments -> New environment

      dev    no protection rules
      prod   Required reviewers: yourself

> This step is easy to skip and it matters. If the environments do not exist,
> GitHub creates them silently on first use **with no protection at all**, and
> the production approval gate the workflows are built around will not exist.
> Nothing in Terraform or in the workflow can enforce it; it is a repository
> setting.

- [ ] Confirm CI is green

      gh run list --repo "$REPO" --limit 5

  Before the variables are set, the cloud jobs skip and the pipeline is green
  on lint, tests, scanning, the integration evaluation and
  `terraform validate`. After they are set, `build`, `apply` and the drift
  check start running on their own.

**Check:** open a trivial pull request touching `infra/` and confirm the
`terraform` workflow posts a plan comment on it.

---

## Phase 6 - Production, when you want it

Read the cost note first.

- [ ] `cd infra/terraform/envs/prod`, same steps as Phase 3
- [ ] Confirm `prod` has a required reviewer before the first apply
- [ ] Run the indexer job for prod
- [ ] Confirm alert emails arrive: trigger one deliberately, or check
      Monitoring -> Alerting -> Notification channels

---

## Cost

`envs/prod` runs regional Cloud SQL with a standby in a second zone and keeps
one Cloud Run instance warm. That is a real monthly bill, in the hundreds of
US dollars, and it accrues whether or not anyone uses the service.

For a demonstration, apply `envs/dev` only: zonal database, Cloud Run scaling
to zero. Leave the prod configuration in the repository as the written
statement of how it would be run. A reviewer reads the configuration; they do
not check your invoice.

- [ ] `billing_account` set in bootstrap so the budget and its alerts exist
- [ ] Budget visible under Billing -> Budgets and alerts

---

## Teardown

```bash
cd infra/terraform/envs/dev
terraform destroy
```

Prod has `deletion_protection = true` on the database, so a destroy there
fails until it is deliberately turned off. That is intentional.

Bootstrap is normally left in place: it holds the state bucket and the
registry. If you do remove it, empty the bucket first, since `force_destroy`
is `false` on purpose.

---

## When something fails

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Error 403: ... API has not been used` | Phase 1 skipped or incomplete | Re-apply bootstrap |
| Cloud Run deploy rejects the image | Image built for arm64 | Rebuild with `--platform linux/amd64` |
| `terraform apply` hangs on Cloud SQL | Normal, 10 to 15 minutes | Wait |
| `/readyz` returns 503 | Database unreachable | Check the private service connection and the `DATABASE_URL` secret |
| `/ask` returns empty `sources` | Index is empty | Run the indexer job (Phase 4) |
| CI: `failed to generate Google Cloud federated token` | Variables wrong, or the attribute condition does not match this repository | Re-check the six variables and `github_repository` in bootstrap |
| Prod deployed without approval | The `prod` environment has no required reviewer | Add one in Settings -> Environments |
| Daily `drift` issue opened | Something was changed outside Terraform | Either commit the change or re-apply from `main` |
