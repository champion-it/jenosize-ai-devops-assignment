# Kubernetes deployment (alternative)

A Helm chart that runs the same two images on Kubernetes.

**This is not the primary deployment path.** The platform runs on Cloud Run,
for the reasons in the root README: request-based autoscaling, scale to zero,
and traffic splitting for canary releases without a cluster to operate. This
chart exists because the same workload has to be portable, and because a
platform decision is easier to judge when the alternative is written down
rather than described.

Nothing here is wired into CI deployment. CI lints and renders it, so it
cannot rot, but no pipeline installs it.

## What it renders

| | dev | prod |
| --- | --- | --- |
| Deployment (api) | 1 replica | 3 replicas, larger requests |
| HorizontalPodAutoscaler | off | 3 to 20 pods on 70% CPU |
| PodDisruptionBudget | off | `minAvailable: 2` |
| CronJob (indexer) | 03:00 ICT | 03:00 ICT |
| NetworkPolicy | default deny plus two rules | same |
| Ingress | off | nginx with a per-minute limit |
| ServiceMonitor | off | scraped every 10s |

Same chart, same templates. The environments differ only in values, which is
the same separation the Terraform environments use.

## Install

```bash
# The chart never contains a credential. In a cluster this Secret comes from
# External Secrets or Sealed Secrets, not from a shell.
kubectl create namespace jenie
kubectl -n jenie create secret generic jenie-database \
  --from-literal=DATABASE_URL='postgresql://user:pass@host:5432/jenie'

helm upgrade --install jenie infra/k8s \
  --namespace jenie \
  -f infra/k8s/values-dev.yaml \
  --set image.registry=<your-registry>
```

Render without installing:

```bash
helm template jenie infra/k8s -f infra/k8s/values-prod.yaml
```

## Decisions worth explaining

**Probes are three, not two.** `startupProbe` gates the other two, so a slow
first boot is not read as a liveness failure and restarted in a loop.
`readinessProbe` hits `/readyz`, which checks the database, so traffic is
held while a dependency is down. `livenessProbe` hits `/healthz`, which
deliberately does not touch the database, because a database blip should not
restart otherwise healthy pods.

**Draining is two steps.** A `preStop` sleep gives the endpoint controller
time to remove the pod from Service endpoints before the process starts
shutting down; without it, requests are still being routed to a pod that is
already draining. `terminationGracePeriodSeconds` then exceeds the
application's own graceful shutdown window.

**Rollouts are `maxUnavailable: 0, maxSurge: 1`.** Capacity never dips during
a release, and a bad image replaces one pod at a time rather than the fleet.

**Autoscaling is asymmetric.** Scale up immediately, scale down over five
minutes. Scaling in on a brief lull only to scale out again costs more than
the idle replicas it would have saved.

**NetworkPolicy denies by default.** One policy selects everything the chart
owns and permits nothing; the rules after it re-open exactly one path each.
A new workload is therefore isolated until someone says otherwise, rather
than reachable until someone notices. The indexer has no ingress rule at
all, because nothing should ever connect to a batch job.

**`DATABASE_URL` is a Secret reference, never a templated value.** A rendered
manifest, a `helm template` in CI output, and a chart in a repository all
stay free of the credential.

**Containers are hardened by default** in a named template rather than per
workload: non-root, read-only root filesystem, all capabilities dropped, no
privilege escalation, `RuntimeDefault` seccomp, and no service account token
mounted, since no pod here talks to the API server.

## Meeting the assignment's "Must include" list on this path

Task 1 asks for four things from whichever IaC option is chosen. Terraform is
the chosen one and covers all four; this chart covers them too, so the
Kubernetes path stands on its own rather than only as an illustration.

| Required | Here |
| --- | --- |
| Separate environments: dev and prod | `values-dev.yaml` and `values-prod.yaml` over one chart |
| Network/security baseline (VPC **or k8s namespaces**) | Namespace with Pod Security Admission at `restricted`, plus default-deny NetworkPolicies |
| Least-privilege IAM | See below |
| Secrets management strategy | ExternalSecret, or a Secret reference |
| DR/backups | See below |

### Least privilege, without theatre

There is no Role or RoleBinding in this chart, and that is the correct answer
rather than an omission: **no pod here talks to the Kubernetes API**. Adding
an empty Role would look like access control while granting nothing.

What is enforced instead is stronger:

- A dedicated ServiceAccount per release, not `default`.
- `automountServiceAccountToken: false` on both the ServiceAccount and every
  pod, so no API token is even present in the container. A token that is not
  mounted cannot be stolen or misused, whatever RBAC says.
- Access to Google Cloud comes from a Workload Identity annotation on the
  ServiceAccount, which maps it to a GCP service account whose roles are
  defined in Terraform. The least-privilege boundary lives there, where the
  resources being protected are.

If a workload later does need API access, the Role belongs with that
workload and should grant exactly the verbs it uses.

### Secrets

`DATABASE_URL` is never templated into a manifest. Two supported paths:

1. **ExternalSecret** (`externalSecret.enabled`, default on in prod). The
   External Secrets Operator pulls the value from Secret Manager on a refresh
   interval, so rotation upstream propagates on its own and the cluster holds
   no long-lived copy.
2. **An existing Secret**, created by Sealed Secrets or by an operator. The
   chart references it by name only.

`kubectl create secret` appears in the install instructions for a first local
run only. It puts the credential in a shell history and leaves a copy in etcd
that every cluster backup then carries, which is why it is not the documented
path for a real cluster.

### DR and backups on this path

The stateful part is not in the cluster. Postgres with pgvector stays on
Cloud SQL, so backups, point-in-time recovery and the restore procedure are
the same as the Terraform path and are documented in
[`infra/terraform/README.md`](../terraform/README.md).

What the cluster holds is derived or declarative:

| | Recovery |
| --- | --- |
| Workloads | Re-apply the chart. Nothing in the cluster is a source of truth. |
| Vector index | Rerun the CronJob against `/data`; it is idempotent and rebuilds with `--force`. |
| Secrets | Re-pulled by ExternalSecret from Secret Manager. Nothing to restore. |
| Cluster loss | Re-create the cluster, re-apply the chart, rerun the indexer. The database is untouched because it was never in the cluster. |

Keeping all persistent state outside the cluster is what makes the cluster
itself disposable, which is the property worth having.

## What is missing compared to the Cloud Run path

Honest gaps, since this is a secondary artifact:

- **No canary.** Rolling update only. Canary on Kubernetes needs Argo Rollouts or a service mesh; on Cloud Run it is one `update-traffic` flag, which is part of why Cloud Run was chosen.
- **No cluster provisioning.** This chart assumes a cluster exists. There is no GKE Terraform in this repository.
- **Not installed anywhere.** It is linted and rendered in CI, and validated structurally, but it has not been applied to a live cluster.
