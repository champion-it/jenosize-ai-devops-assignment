# Deployment checklist

From an empty AWS account to a running service, in order. Each phase ends
with a command that proves it worked, so a failure is caught where it
happened rather than three steps later.

> **Read the cost note first.** This platform does not scale to zero. The
> EKS control plane alone is about $73 a month from the moment it exists,
> and the whole stack is roughly $155. Phase 7 is how you stop it.

```bash
export AWS_REGION="ap-southeast-1"
export REPO="champion-it/jenosize-ai-devops-assignment-yodthong"
export ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export ECR="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/jenie"
```

---

## Phase 0 - Prerequisites

- [ ] `aws` CLI installed and configured

      brew install awscli
      aws configure          # access key, secret, region
      aws sts get-caller-identity

- [ ] `terraform` >= 1.9, `kubectl`, `helm`, `docker`

- [ ] The Argo Rollouts kubectl plugin, for watching a canary

      brew install argoproj/tap/kubectl-argo-rollouts

**Check:** `aws sts get-caller-identity` prints your account id.

---

## Phase 1 - Bootstrap

Creates the state backend, the image registry, the GitHub OIDC provider and
the two CI roles.

```bash
cd infra/terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars
# state_bucket_name must be globally unique across all of S3
terraform init
terraform apply
```

**Check:**

```bash
aws s3api head-bucket --bucket "$(terraform output -raw state_bucket)"
aws ecr describe-repositories --repository-names jenie/api jenie/worker --region "$AWS_REGION"
aws iam list-open-id-connect-providers
```

> The OIDC trust policy is pinned to one repository by name. If you forked
> or renamed, change `github_repository` and re-apply, or CI is refused a
> token.

---

## Phase 2 - Build and push the first images

The cluster pulls by tag, and a pod whose image does not exist sits in
`ImagePullBackOff`. Images come before the first apply; CI owns them after.

```bash
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

cd "$(git rev-parse --show-toplevel)"
docker buildx build --platform linux/amd64 -f api/Dockerfile    -t "$ECR/api:bootstrap"    --push .
docker buildx build --platform linux/amd64 -f worker/Dockerfile -t "$ECR/worker:bootstrap" --push .
```

> `--platform linux/amd64` is not optional on an Apple Silicon Mac. Without
> it Docker builds arm64, Fargate refuses the image, and the error names a
> manifest rather than the architecture, which is a slow thing to debug.

**Check:**

```bash
aws ecr describe-images --repository-name jenie/api --region "$AWS_REGION" \
  --query 'imageDetails[].imageTags'
```

---

## Phase 3 - The cluster

This is the expensive one, and it takes 15 to 20 minutes.

```bash
cd infra/terraform/cluster
cp backend.hcl.example backend.hcl        # bucket and lock table from Phase 1
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config=backend.hcl
terraform plan                             # read it before applying
terraform apply
```

**Check:**

```bash
eval "$(terraform output -raw update_kubeconfig)"
kubectl -n argo-rollouts get deploy argo-rollouts
kubectl -n kube-system get deploy aws-load-balancer-controller
aws amp list-workspaces --region "$AWS_REGION"
```

Both controllers must report `Available`. A Rollout without its controller
is an inert object and nothing will tell you so.

- [ ] Confirm the SNS subscription that arrives by email, or alerts go nowhere

---

## Phase 4 - The prod database

The cluster root creates the instance and the dev database. Prod gets its
own database on the same instance, which Terraform cannot create because it
has no Postgres connection from outside the VPC.

```bash
kubectl -n jenie-dev run psql --rm -it --restart=Never \
  --image=postgres:16-alpine -- \
  psql "$(aws secretsmanager get-secret-value --region "$AWS_REGION" \
    --secret-id jenie/database-url --query SecretString --output text)"
```

```sql
CREATE DATABASE jenie_prod;
-- Postgres lets any role connect to any database until this is revoked.
-- Without it, a leaked dev credential is also a prod credential.
REVOKE CONNECT ON DATABASE jenie_prod FROM jenie_app;
```

**Check:** `\l` lists both `jenie` and `jenie_prod`.

---

## Phase 5 - Deploy dev

```bash
cd infra/terraform/envs/dev
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config=backend.hcl
terraform apply
eval "$(terraform output -raw helm_command)"
```

**Check:**

```bash
kubectl -n jenie-dev rollout status deploy/jenie-helpdesk-ai-dev-api
kubectl -n jenie-dev port-forward svc/jenie-helpdesk-ai-dev-api 8000:80 &
curl -fsS localhost:8000/healthz
curl -fsS localhost:8000/readyz
```

A failing `/readyz` with a healthy `/healthz` means the database is not
reachable. Check the security group, and that the service account picked up
its role: `kubectl -n jenie-dev describe sa jenie-helpdesk-ai-dev`.

---

## Phase 6 - Index, then verify retrieval

```bash
kubectl -n jenie-dev create job --from=cronjob/jenie-helpdesk-ai-dev-indexer indexer-manual
kubectl -n jenie-dev wait --for=condition=complete job/indexer-manual --timeout=5m

python3 scripts/eval.py --base-url http://localhost:8000
```

**Check:** the evaluation reports a 100 percent pass rate. Empty `sources`
means the index is empty; read the job's logs.

---

## Phase 7 - Stop paying

Do this the moment the demo is over. Set the reminder now, not later.

```bash
cd infra/terraform/envs/dev && terraform destroy
cd ../../cluster            && terraform destroy   # the $73/month one
```

Bootstrap is cheap to leave: S3, ECR and IAM cost pennies. If you remove it
too, empty the bucket first.

**Check:**

```bash
aws eks list-clusters --region "$AWS_REGION"                 # empty
aws rds describe-db-instances --region "$AWS_REGION" \
  --query 'DBInstances[].DBInstanceIdentifier'               # empty
```

---

## Phase 8 - Production, and watching a canary decide

```bash
cd infra/terraform/envs/prod   # same steps as Phase 5
```

- [ ] The `prod` GitHub Environment has a required reviewer **before** the first run

> GitHub creates a missing environment silently on first use **with no
> protection at all**. The approval gate the workflows are built around does
> not exist until the environment is created deliberately. Nothing in
> Terraform or in the workflow can enforce it.

Watch a release make its own decision:

```bash
kubectl argo rollouts get rollout jenie-helpdesk-ai-prod-api -n jenie-prod --watch
```

It shifts to 10 percent, runs the analysis against Managed Prometheus, and
either proceeds or aborts. To see it abort on purpose, deploy an image that
returns errors and watch the run fail:

```bash
kubectl -n jenie-prod get analysisrun \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,MESSAGE:.status.message
```

---

## Phase 9 - Hand over to CI/CD

```bash
cd infra/terraform/bootstrap
terraform output -json github_repository_variables \
  | jq -r 'to_entries[] | "\(.key)=\(.value)"' \
  | while IFS='=' read -r k v; do gh variable set "$k" --body "$v" --repo "$REPO"; done

# EKS_CLUSTER_NAME comes from the cluster root, not from bootstrap
gh variable set EKS_CLUSTER_NAME --repo "$REPO" \
  --body "$(cd ../cluster && terraform output -raw cluster_name)"
```

Before the variables are set, the cloud jobs skip and the pipeline is green
on lint, tests, scanning, the integration evaluation and `terraform
validate`. After they are set, build, deploy and the drift check start
running on their own.

---

## When something fails

| Symptom | Cause | Fix |
| --- | --- | --- |
| Pods stuck `Pending` | No Fargate profile matches the namespace | Add it to `fargate_namespaces`, re-apply the cluster |
| `ImagePullBackOff` | Image missing, or built for arm64 | Phase 2, with `--platform linux/amd64` |
| `/readyz` returns 503 | Database unreachable | Security group, and the service account's role annotation |
| Ingress never gets an address | Load balancer controller down, or subnets untagged | `kubectl -n kube-system logs deploy/aws-load-balancer-controller` |
| Rollout sits at 10 percent | The analysis cannot reach Prometheus | `prometheusAddress`, and the controller's IAM role |
| Canary aborts immediately | Correct, if the indicators really are bad. Otherwise too little traffic to measure | `kubectl -n jenie-prod describe analysisrun` |
| CI: `Not authorized to perform sts:AssumeRoleWithWebIdentity` | Repository name does not match the OIDC trust policy | Re-apply bootstrap with the right `github_repository` |
| A bill larger than expected | The cluster is still running | Phase 7 |
