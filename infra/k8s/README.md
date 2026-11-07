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

## What is missing compared to the Cloud Run path

Honest gaps, since this is a secondary artifact:

- **No canary.** Rolling update only. Canary on Kubernetes needs Argo Rollouts or a service mesh; on Cloud Run it is one `update-traffic` flag, which is part of why Cloud Run was chosen.
- **No cluster provisioning.** This chart assumes a cluster exists. There is no GKE Terraform in this repository.
- **Not installed anywhere.** It is linted and rendered in CI, and validated structurally, but it has not been applied to a live cluster.
