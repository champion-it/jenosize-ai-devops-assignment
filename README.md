# Jenie Helpdesk AI - Platform

A secure, observable, production-ready platform for an AI-enabled web service.
The service answers questions from a knowledge base using RAG (retrieval + LLM).

Submitted for the Jenosize AI DevOps Engineer test assignment.

---

## 1. Quick start

```bash
cp .env.example .env
docker compose up -d --build postgres redis api
docker compose run --rm worker --path /data
curl -s localhost:8000/ask -H 'content-type: application/json' \
  -d '{"query":"How do I reset my password?"}'
```

Add the monitoring stack with `docker compose up -d prometheus grafana`, then
open Grafana at http://localhost:3000 (anonymous viewer access is enabled).

| Service | URL |
| --- | --- |
| API | http://localhost:8000 |
| Metrics | http://localhost:8000/metrics |
| Grafana | http://localhost:3000 |
| Prometheus | http://localhost:9090 |

---

## 2. Scope

Two application services plus their dependencies:

| Component | Role |
| --- | --- |
| `api` | FastAPI service. Exposes `/healthz`, `/readyz`, `/ingest`, `/ask`, `/metrics`. |
| `worker` | Indexer. Chunks documents, builds embeddings, writes to the vector store. |
| Postgres + pgvector | Metadata and vector store in one engine. |
| Redis | Optional response cache and ingest queue. |

The LLM call is mocked behind a provider interface. The assignment allows this
explicitly, and it keeps the focus on infrastructure and operations. Swapping
in a real provider is a configuration change, not a code change - see
[Provider switching](#8-provider-switching).

---

## 3. Architecture

```
                         Internet
                             |
                    [ Cloud Armor / WAF ]
                  rate limit, SQLi and XSS rules
                             |
                 +-----------v------------+
                 |   Cloud Run: api       |
                 |   FastAPI, autoscaled  |
                 |   /healthz /readyz     |
                 |   /ask /metrics        |
                 +--+-----------------+---+
                    |                 |
         retrieval  |                 |  cache
                    |                 |
      +-------------v------+   +------v--------+
      |  Cloud SQL         |   |  Memorystore  |
      |  Postgres+pgvector |   |  Redis        |
      |  private IP only   |   +---------------+
      +-------------^------+
                    |
          writes    |
                    |
      +-------------+------------+        +------------------+
      |  Cloud Run Job: worker   |<-------| Cloud Scheduler  |
      |  chunk, embed, upsert    |        | nightly reindex  |
      +-------------^------------+        +------------------+
                    |
              +-----+------+
              |    /data   |
              |  *.md docs |
              +------------+

  Observability: the API exports Prometheus metrics and JSON logs, scraped by
  Prometheus locally and by Managed Service for Prometheus on GCP. The same
  dashboards and alert rules apply in both.
```

### Request path for `POST /ask`

1. Embed the incoming query.
2. Vector search in pgvector, returning the top-k chunks with scores.
3. Build a prompt from the retrieved chunks, within a fixed context budget.
4. Call the LLM provider (mock by default) to produce the answer.
5. Return the answer, its sources, and the measured latency.

Retrieval and generation are timed separately, so a latency regression can be
attributed to the vector search or to the model without guessing.

---

## 4. Repository layout

```
.
├── common/                      shared by both services
│   ├── config.py                environment-driven settings
│   ├── db.py                    connection pool, schema, vector helpers
│   ├── chunker.py               heading-aware markdown splitting
│   ├── embeddings.py            embedding provider interface
│   └── observability/
│       ├── logging.py           structured JSON logging
│       └── metrics.py           Prometheus metric definitions
├── api/
│   ├── Dockerfile
│   └── app/
│       ├── main.py              FastAPI entrypoint, routes, middleware
│       ├── ratelimit.py         in-process fixed-window limiter
│       ├── rag/
│       │   ├── retriever.py     pgvector similarity search
│       │   └── llm.py           LLM provider interface (mock | vertex | openai)
│       └── tests/
├── worker/
│   ├── Dockerfile
│   ├── indexer/main.py          idempotent batch indexing
│   └── tests/
├── infra/
│   └── terraform/
│       ├── modules/
│       │   ├── network/         VPC, private service access, Cloud Armor
│       │   ├── database/        Cloud SQL, backups, DATABASE_URL secret
│       │   ├── service/         Cloud Run service and job, service accounts
│       │   └── observability/   alert policies, log sink, log-based metrics
│       ├── envs/dev/
│       ├── envs/prod/
│       └── README.md            state, ownership, DR and backup strategy
├── observability/
│   ├── grafana/
│   │   ├── dashboards/          exported dashboard JSON
│   │   └── provisioning/
│   ├── prometheus/prometheus.yml
│   └── alerts/rules.yml         four alert rules
├── data/                        12 markdown knowledge base documents
├── scripts/
│   ├── eval.py                  retrieval evaluation and CI gate
│   └── eval_queries.json
├── .github/workflows/
│   ├── ci.yml                   lint, test, scan, integration, build, push
│   └── deploy.yml               dev deploy, prod canary, rollback
├── docker-compose.yml
├── README.md
└── SECURITY.md
```

Both Dockerfiles build from the repository root so `common/` is shared without
vendoring it twice.

---

## 5. Technology choices

| Area | Choice | Reason |
| --- | --- | --- |
| Cloud | Google Cloud | The assignment accepts GCP. Cloud Run gives request-based autoscaling, scale to zero, and traffic splitting for canary releases without running a cluster. |
| IaC | Terraform | Preferred by the assignment. The same modules build both environments, which differ only in the values they pass. |
| Compute | Cloud Run service + Cloud Run Job | The API is request-driven, the indexer is batch. Separating them means a large ingest cannot consume API capacity or hit a request timeout. |
| Vector store | Cloud SQL Postgres with pgvector | One managed engine for metadata and vectors: one backup, one restore procedure, one network path to secure. |
| Vector index | HNSW | IVFFlat computes its centroids when the index is built. Built on an empty table it returns no rows at all until rebuilt. HNSW builds incrementally and is correct from empty onwards. |
| CI/CD | GitHub Actions with Workload Identity Federation | No long-lived service account key in the repository or in GitHub secrets. |
| Registry | Artifact Registry | Native to GCP, integrates with Cloud Run and vulnerability scanning. |
| Metrics | `prometheus-client`, Prometheus exposition format | Identical in docker-compose and on Cloud Run via Managed Service for Prometheus. Portable, not tied to one vendor. |
| Secrets | Secret Manager, mounted by reference at runtime | Secrets never enter an image or the repository. |

On AWS the mapping is ECS Fargate, RDS Postgres with pgvector, ECR and Secrets
Manager. The application code does not change; only the `infra` module
implementations would.

---

## 6. Environments

Two environments built from the same modules.

| | dev | prod |
| --- | --- | --- |
| Cloud SQL | `db-custom-1-3840`, zonal | `db-custom-2-7680`, regional with failover |
| Backups | daily, 7 retained | daily, 30 retained, point-in-time recovery |
| Min instances | 0, scales to zero | 1, avoids a cold start on the first request |
| Edge | direct, so CI can smoke test it | Cloud Armor |
| Log retention | 14 days | 90 days |
| Deletion protection | off | on |
| Release | deploy takes all traffic | canary at 10 percent, then promote |

Terraform state lives in a versioned GCS bucket, one prefix per environment.
See [`infra/terraform/README.md`](infra/terraform/README.md).

---

## 7. Endpoints

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/healthz` | Liveness. Does not touch dependencies, so a database blip cannot restart healthy instances. |
| GET | `/readyz` | Readiness. Verifies database connectivity so traffic is held during startup. |
| POST | `/ingest` | Runs an indexing pass. In GCP the indexer normally runs as a Cloud Run Job instead. |
| POST | `/ask` | Answers a query from the knowledge base. |
| GET | `/metrics` | Prometheus exposition. |

`POST /ask` response:

```json
{
  "answer": "...",
  "sources": [{ "title": "Password Reset", "score": 0.1249 }],
  "latency_ms": 2
}
```

---

## 8. Provider switching

Embeddings and the LLM both sit behind an interface selected by environment
variable, so the same image runs against a mock or a real provider.

| Variable | Values | Default |
| --- | --- | --- |
| `EMBEDDING_PROVIDER` | `hashing`, `vertex` | `hashing` |
| `EMBEDDING_DIM` | any width under 2000 for HNSW | `768` |
| `LLM_PROVIDER` | `mock`, `vertex`, `openai` | `mock` |

`hashing` is a deterministic lexical embedding built from hashed word
unigrams and bigrams with stopword removal and sublinear term weighting. It
needs no model download, no GPU and no network, so `docker compose up` works
offline and CI runs in seconds. `vertex` routes the same pipeline to Vertex AI.

`EMBEDDING_DIM` must match between the API and the worker: the vector column
width is fixed when the schema is created, and an insert of a different width
is rejected. Both compose and Terraform pass it explicitly for that reason.

---

## 9. Observability

Metrics exported by the API:

| Metric | Type | Purpose |
| --- | --- | --- |
| `http_requests_total` | counter | request count by method, route and status class |
| `http_request_duration_seconds` | histogram | p50/p95/p99 latency per route |
| `rag_retrieval_duration_seconds` | histogram | embedding and vector search time |
| `rag_answer_duration_seconds` | histogram | LLM generation time |
| `rag_retrieved_score` | histogram | top match score, a drift signal |
| `rag_empty_retrieval_total` | counter | queries matching nothing at all |
| `llm_tokens_total` | counter | prompt and completion tokens by provider |
| `llm_cost_usd_total` | counter | cost proxy derived from tokens and a configurable rate |
| `ingest_documents_total` | counter | documents indexed or skipped |
| `ingest_duration_seconds` | histogram | duration of an indexing run |

Logs are JSON, one object per line, with a request id on every line and
`severity` named so Cloud Logging promotes it to the entry severity. The
request middleware logs timing and match counts; the query body is never
logged, so logs do not become a copy of user input.

Alert rules in [`observability/alerts/rules.yml`](observability/alerts/rules.yml):

1. `HighErrorRate` - 5xx rate above 5 percent for 5 minutes.
2. `HighAskLatency` - p95 on `/ask` above 2 seconds for 10 minutes.
3. `RetrievalQualityDrop` - more than 20 percent of queries retrieve nothing.
4. `ApiDown` - the metrics endpoint is unreachable.

The Grafana dashboard
([`observability/grafana/dashboards/jenie-overview.json`](observability/grafana/dashboards/jenie-overview.json))
covers traffic, error rate, a 30-day availability SLO, latency quantiles, the
retrieval-versus-answer split, retrieval quality, token throughput, cost per
24 hours and cost per 1000 requests.

On GCP, `infra/terraform/modules/observability` adds the platform-level alerts
Prometheus cannot see, including a log-based metric that alerts when the batch
indexer fails.

---

## 10. CI/CD

`ci.yml` runs on every pull request and every push to `main`:

1. `ruff check` and `ruff format --check`.
2. `pytest` with coverage.
3. Trivy filesystem scan for vulnerabilities, secrets and misconfiguration.
4. Integration: start the stack, index the corpus, run the retrieval
   evaluation as a gate.
5. Build both images, scan each with Trivy, and push only after the scan
   passes, so a vulnerable image never reaches the registry.

Images are tagged with `git describe` and with the commit SHA, so any deployed
revision is traceable to a commit.

`deploy.yml` deploys to dev automatically, then waits on a GitHub environment
with a required reviewer before prod. The prod release records the currently
serving revision, deploys the new one with no traffic under a `candidate` tag,
verifies it on its own URL, shifts 10 percent, holds long enough for the error
rate alert window to cover it, then promotes. Any failure shifts traffic back
to the recorded revision; nothing is rebuilt, so rollback takes seconds.

---

## 11. Security

Full detail, including the gaps that were accepted and why, is in
[SECURITY.md](SECURITY.md). Summary:

- No secrets in the repository; Secret Manager at runtime, Trivy secret scanning in CI.
- Workload Identity Federation for CI, so no static cloud credential exists.
- One least-privilege service account per workload.
- Cloud SQL on private IP only, VPC denies ingress by default, flow logs on.
- Cloud Armor rate limiting plus SQLi and XSS rule sets, with an in-process limiter as the fallback.
- Containers run as a non-root user with a read-only root filesystem and all capabilities dropped.

The largest gap, stated plainly: there is no end-user authentication or
per-tenant retrieval scoping. The assignment specifies an open API, and
identity in front of the service is the first thing a real deployment needs.

---

## 12. Evaluation

`scripts/eval.py` runs a fixed query set against a running API and reports, per
query, whether the document that should answer it appears in the sources,
together with reciprocal rank and latency. It exits non-zero when the pass rate
or p95 latency breaches the threshold, so the same script is a local check and
a CI gate after deploy.

```bash
python scripts/eval.py --base-url http://localhost:8000
```

Measured on this corpus with the default `hashing` provider:

```
pass rate 100%  mrr 0.950  p50 3 ms  p95 14 ms
PASSED
```

It measures retrieval, not answer wording. With the mock provider, scoring the
generated text would only measure the mock.

A note on what the score means: off-topic queries score 0.07 to 0.12 against
this corpus while the lowest correct match scores 0.078, so the ranges overlap
and no absolute cut-off separates relevant from irrelevant. The score floor in
the retriever only drops chunks with essentially no lexical overlap, and the
score is treated as a drift signal over time rather than per-query confidence.
A semantic embedding provider gives a better separated distribution.

---

## 13. Disaster recovery

| Concern | Approach |
| --- | --- |
| Database loss | Daily backups; point-in-time recovery in prod. Prod RPO under 5 minutes, dev 24 hours. |
| Zone loss | Regional Cloud SQL in prod with automatic failover. |
| Region loss | Backups replicated to a multi-region location; restore and re-apply with a new region. |
| Index corruption | The index is derived data. Rerun the worker against `/data`; it is idempotent and rebuilds with `--force`. |
| Bad release | Cloud Run retains revisions. Rollback is a traffic shift, not a rebuild. |
| State corruption | GCS object versioning on the Terraform state bucket. |

Detail and the intended restore drill are in
[`infra/terraform/README.md`](infra/terraform/README.md).

---

## 14. Verification

Everything below was run against the stack in this repository, not asserted
from the configuration.

| Check | Result |
| --- | --- |
| Unit tests | 36 passed |
| `ruff check` / `ruff format --check` | clean |
| `terraform validate`, dev and prod | both valid |
| `terraform fmt -check -recursive` | clean |
| Ingest | 12 documents, 45 chunks, 79 ms |
| Retrieval evaluation | pass rate 100 percent, MRR 0.950, p95 14 ms |
| Rate limiter at 60/min | 60 × 200, then 5 × 429 |
| Prometheus target | up, four alert rules loaded and healthy |
| Grafana | dashboard provisioned, every panel query returns data |

---

## 15. Assignment coverage

| Requirement | Weight | Where |
| --- | --- | --- |
| IaC and environment design | 20% | `infra/terraform/`, sections 5 and 6 |
| CI/CD quality | 20% | `.github/workflows/`, section 10 |
| Observability | 20% | `observability/`, section 9 |
| Security | 15% | [SECURITY.md](SECURITY.md), section 11 |
| AI workload readiness | 15% | `worker/`, `scripts/eval.py`, sections 3, 8 and 12 |
| Documentation | 10% | this file and `infra/terraform/README.md` |
