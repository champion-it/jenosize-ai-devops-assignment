"""Prometheus metrics.

Exposed in the Prometheus text format on /metrics. The same endpoint is
scraped by the local Prometheus in docker-compose and by Managed Service for
Prometheus on GCP, so the dashboards and alert rules are identical in both.

Latency is split into retrieval and answer so a regression can be attributed
to the vector search or to the model without guessing. Token counters give
the cost proxy the assignment asks for.
"""

from __future__ import annotations

from prometheus_client import CollectorRegistry, Counter, Histogram

REGISTRY = CollectorRegistry()

LATENCY_BUCKETS = (0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0)

http_requests_total = Counter(
    "http_requests_total",
    "HTTP requests by route and status class.",
    ["method", "route", "status"],
    registry=REGISTRY,
)

http_request_duration_seconds = Histogram(
    "http_request_duration_seconds",
    "End to end HTTP request duration.",
    ["method", "route"],
    buckets=LATENCY_BUCKETS,
    registry=REGISTRY,
)

rag_retrieval_duration_seconds = Histogram(
    "rag_retrieval_duration_seconds",
    "Time spent embedding the query and searching the vector store.",
    buckets=LATENCY_BUCKETS,
    registry=REGISTRY,
)

rag_answer_duration_seconds = Histogram(
    "rag_answer_duration_seconds",
    "Time spent in the LLM provider producing an answer.",
    buckets=LATENCY_BUCKETS,
    registry=REGISTRY,
)

rag_retrieved_score = Histogram(
    "rag_retrieved_score",
    "Similarity score of the best match per query. A drop signals drift "
    "between the questions being asked and the indexed corpus.",
    buckets=(0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0),
    registry=REGISTRY,
)

rag_empty_retrieval_total = Counter(
    "rag_empty_retrieval_total",
    "Queries that returned no chunk above the score floor.",
    registry=REGISTRY,
)

llm_tokens_total = Counter(
    "llm_tokens_total",
    "Tokens consumed by the LLM provider.",
    ["provider", "model", "kind"],
    registry=REGISTRY,
)

llm_cost_usd_total = Counter(
    "llm_cost_usd_total",
    "Cost proxy in USD derived from token counts and the configured rate.",
    ["provider", "model"],
    registry=REGISTRY,
)

ingest_documents_total = Counter(
    "ingest_documents_total",
    "Documents processed by the indexer.",
    ["result"],
    registry=REGISTRY,
)

ingest_duration_seconds = Histogram(
    "ingest_duration_seconds",
    "Duration of a full indexing run.",
    buckets=(0.5, 1.0, 2.5, 5.0, 10.0, 30.0, 60.0, 300.0),
    registry=REGISTRY,
)
