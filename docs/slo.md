# Service level objectives

What "working" means for Jenie Helpdesk AI, stated precisely enough that a
dashboard can answer it and an alert can act on it.

## Service level indicators

An SLI is a ratio of good events to valid events. Both are measured from the
same metrics the service already exports, so nothing here depends on a
separate measurement pipeline that could drift from reality.

### Availability

```promql
sum(rate(http_requests_total{status!="5xx"}[w]))
/ sum(rate(http_requests_total[w]))
```

A request counts as good unless the service returned 5xx. A 4xx is the
caller's problem and does not spend the budget; a malformed query is not an
outage.

### Latency

```promql
sum(rate(http_request_duration_seconds_bucket{route="/ask",le="2.0"}[w]))
/ sum(rate(http_request_duration_seconds_count{route="/ask"}[w]))
```

A request counts as good if it completed within 2 seconds. The histogram
carries a bucket edge at exactly 2.0 for this reason: a histogram can only
answer questions its edges line up with, so the objective picks the bucket
rather than the bucket quietly redefining the objective.

Only `/ask` is measured. `/healthz`, `/readyz` and `/metrics` are polled
constantly and would dominate the ratio while telling nobody anything.

## Objectives

| SLO | Target | Window | Budget |
| --- | --- | --- | --- |
| Availability | 99.0% of requests non-5xx | 30 days rolling | 1%, which is 7h 12m of total failure |
| Latency | 99.0% of `/ask` under 2s | 30 days rolling | 1% of requests may be slow |

Both targets are deliberately not 99.9%. An objective that the team cannot
actually hold is worse than a lower one that it can: it trains everyone to
ignore the alert. 99% is defensible for a helpdesk assistant, and raising it
is a decision to take once the service has a track record rather than a
number to pick optimistically on day one.

The window is rolling rather than calendar-aligned, so a bad day keeps
costing budget for thirty days instead of being forgiven at midnight on the
first.

## Error budget

A 99% objective means 1% of requests are allowed to fail. That 1% is not
waste to be minimised to zero; it is the room that makes shipping possible.
Spending none of it means the service is overbuilt for its objective.

Budget consumed over the window:

```promql
(
  sum(increase(http_requests_total{status="5xx"}[30d]))
  / sum(increase(http_requests_total[30d]))
) / 0.01
```

`1.0` means the budget is exactly spent.

### Policy when the budget runs out

1. **Feature releases pause.** Only reliability work and rollbacks deploy.
2. **The next piece of work is whatever spent the budget**, not the next item
   on the roadmap.
3. **It resumes when the rolling window recovers**, not when someone decides
   enough time has passed.

Writing the policy down is the point. An error budget nobody acts on is a
chart, not a control.

## Burn rate alerting

A static "error rate above 5%" threshold fires at the same point whether the
service has been failing for thirty seconds or thirty minutes, and says
nothing about whether the month is still recoverable. These alerts fire on
how fast the budget is being spent.

Burn rate 1 spends the budget exactly over the window. Burn rate 14.4 spends
2% of a 30-day budget in one hour.

| Burn | Long window | Short window | Budget spent before firing | Severity |
| --- | --- | --- | --- | --- |
| 14.4x | 1h | 5m | 2% | page |
| 6x | 6h | 30m | 5% | page |
| 3x | 1d | 2h | 10% | ticket |
| 1x | 3d | 6h | 10% | ticket |

Each alert requires both windows to agree. The long window sets the
severity; the short one makes the alert resolve quickly once the problem
does, so a five minute outage does not hold a page open for an hour.

Only the two fast burns page. The slow ones are tickets, because a budget
that will run out in ten days does not need anyone woken up.

Rules: [`observability/alerts/rules.yml`](../observability/alerts/rules.yml).

### The same objectives in production

Prometheus rules only run where a Prometheus is running, which on Cloud Run
is nowhere. Left alone, these objectives would be real in docker-compose and
absent in production - the worst of both, because the repository would show
alerting that does not exist.

Two pieces close that:

1. **The metrics reach Google.** The Cloud Run service runs an OpenTelemetry
   Collector sidecar that scrapes the application over loopback inside the
   same instance and writes to Managed Service for Prometheus. Metric names
   are unchanged, so every expression here describes the same series in both
   places. The scrape interval is 30s rather than 10s, which cuts sample
   volume by about two thirds and costs nothing in accuracy when the
   shortest burn window is five minutes.

2. **The alerts evaluate there.** Cloud Monitoring runs PromQL directly
   against Managed Service for Prometheus, so the same expressions become
   alert policies. It does not evaluate recording rules, so
   `scripts/render_slo_alerts.py` inlines them and writes
   `infra/terraform/modules/observability/slo_alerts.json`, which Terraform
   reads.

The generated file is committed and CI re-renders it with `--check`. If a
threshold changes here without the policies being re-rendered, the build
fails. That is the mechanism that keeps one definition rather than two that
drift, and it is tested: changing a burn rate makes the check exit non-zero.

Cost: roughly 99 active series at a 30s scrape is about 10M samples a month.
Managed Service for Prometheus bills per sample ingested.

### Two things these expressions get wrong if written naively

Both were found by testing the rules against a running service rather than
by reading them, and both are the kind of defect that leaves the rule
reporting `health: ok` while being useless.

**An absent series is not zero.** With no 5xx anywhere,
`sum(rate(http_requests_total{status="5xx"}[5m]))` returns an empty vector,
not `0`. Dividing an empty vector by anything yields an empty vector, so the
ratio never exists and the alert can never fire - including during the
outage it was written for. `or vector(0)` is what turns "no errors" into
zero instead of nothing.

**`1 - good/total` is 1 when there is no traffic.** Written that way, the
latency ratio reads as "100% of requests are too slow" during any quiet
period, and pages at 3am because nobody was using the service. Expressed as
`slow/total` it is `0` when nothing happened, which is the truth.

## What is deliberately not an SLO

**Retrieval quality.** `rag_empty_retrieval_total` and `rag_retrieved_score`
are tracked and alerted on, but a query that retrieves nothing still returns
a correct, honest answer. It is a quality signal, not an availability one,
and folding it into the SLO would make the error budget mean two things at
once.

**AI cost.** Tracked as `llm_cost_usd_total` and alerted on when it spikes,
but cost is a budget in the financial sense and does not belong in the
reliability one.

**Indexer success.** A batch job, not user-facing. A failed run is alerted
through a log-based metric; it does not spend the request budget.

## Measuring the delivery metrics

The role's success metrics include the four DORA measures. They are not SLOs
and are not alerted on, but the data to compute them already exists:

| Metric | Source |
| --- | --- |
| Deployment frequency | Successful `deploy` workflow runs, from the GitHub API |
| Lead time for changes | Commit authored time to the deploy that shipped it |
| Change failure rate | Deploys followed by a rollback or an incident label |
| Time to restore | Incident opened to resolved |

`scripts/dora.py` computes the first two from the repository and the
workflow history. The latter two need an incident record to join against,
which a real deployment would have and this assignment does not; the script
reports them as unavailable rather than inventing a number.

## Cloud cost per request

Not yet measured. The approach, for when there is a real project to measure:
enable billing export to BigQuery, join daily spend against
`sum(increase(http_requests_total[1d]))`, and publish cost per thousand
requests next to the AI cost that is already on the dashboard. Only the AI
portion is tracked today, and the dashboard labels it as such rather than
implying it is the whole bill.
