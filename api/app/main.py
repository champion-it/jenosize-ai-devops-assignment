"""Jenie Helpdesk AI - API service."""

from __future__ import annotations

import logging
import time
import uuid
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest
from pydantic import BaseModel, Field

from api.app.rag.llm import build_llm_provider
from api.app.rag.retriever import Retriever
from api.app.ratelimit import FixedWindowRateLimiter
from common.config import get_settings
from common.db import Database
from common.embeddings import build_embedding_provider
from common.observability import metrics
from common.observability.logging import configure_logging
from common.observability.tracing import configure_tracing, get_tracer

logger = logging.getLogger("jenie.api")
settings = get_settings()


class AskRequest(BaseModel):
    query: str = Field(min_length=1, max_length=2000)
    top_k: int | None = Field(default=None, ge=1, le=20)


class Source(BaseModel):
    title: str
    score: float


class AskResponse(BaseModel):
    answer: str
    sources: list[Source]
    latency_ms: int


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Tracing first: configure_logging attaches the trace id to every record,
    # so the provider has to exist before the first log line is written.
    configure_tracing(
        settings.service_name,
        settings.environment,
        settings.otel_exporter_otlp_endpoint,
        settings.otel_sample_ratio,
    )
    configure_logging(settings.service_name, settings.environment, settings.log_level)

    database = Database(settings.database_url, settings.embedding_dim)
    database.open()
    database.migrate()

    embeddings = build_embedding_provider(
        settings.embedding_provider, settings.embedding_dim
    )
    app.state.database = database
    app.state.retriever = Retriever(database, embeddings)
    app.state.llm = build_llm_provider(settings.llm_provider, settings.llm_model)
    app.state.limiter = FixedWindowRateLimiter(settings.rate_limit_per_minute)

    logger.info(
        "service started",
        extra={
            "embedding_provider": embeddings.name,
            "llm_provider": app.state.llm.name,
            "environment": settings.environment,
        },
    )
    try:
        yield
    finally:
        # Cloud Run sends SIGTERM and waits before killing the container.
        # Closing the pool here drains in-flight queries instead of dropping
        # them, which is what makes a rolling or canary release clean.
        logger.info("service stopping, draining connections")
        database.close()


app = FastAPI(
    title="Jenie Helpdesk AI",
    version="1.0.0",
    lifespan=lifespan,
)

# One server span per request, with the incoming traceparent honoured so a
# trace started by a caller continues here rather than starting again.
# /metrics and the health probes are excluded: they are scraped and polled
# constantly and would bury the spans that matter.
FastAPIInstrumentor.instrument_app(app, excluded_urls="/metrics,/healthz,/readyz")

tracer = get_tracer("jenie.api")


@app.middleware("http")
async def observability_middleware(request: Request, call_next):
    request_id = request.headers.get("x-request-id") or uuid.uuid4().hex
    route = request.url.path
    started = time.perf_counter()

    try:
        response = await call_next(request)
    except Exception:
        duration = time.perf_counter() - started
        metrics.http_requests_total.labels(request.method, route, "5xx").inc()
        metrics.http_request_duration_seconds.labels(request.method, route).observe(
            duration
        )
        logger.exception(
            "unhandled error",
            extra={"request_id": request_id, "route": route},
        )
        return JSONResponse(
            {"detail": "internal server error", "request_id": request_id},
            status_code=500,
            headers={"x-request-id": request_id},
        )

    duration = time.perf_counter() - started
    status_class = f"{response.status_code // 100}xx"
    metrics.http_requests_total.labels(request.method, route, status_class).inc()
    metrics.http_request_duration_seconds.labels(request.method, route).observe(duration)
    response.headers["x-request-id"] = request_id

    if route != "/metrics":
        logger.info(
            "request completed",
            extra={
                "request_id": request_id,
                "route": route,
                "method": request.method,
                "status": response.status_code,
                "duration_ms": round(duration * 1000, 2),
            },
        )
    return response


@app.get("/healthz")
async def healthz() -> dict[str, str]:
    """Liveness. Must not touch dependencies, or a database blip restarts pods."""
    return {"status": "ok"}


@app.get("/readyz")
async def readyz() -> Response:
    """Readiness. Fails while the database is unreachable so traffic is held."""
    try:
        app.state.database.ping()
    except Exception:
        logger.warning("readiness check failed", exc_info=True)
        return JSONResponse({"status": "unavailable"}, status_code=503)
    return JSONResponse({"status": "ready"})


@app.get("/metrics")
async def prometheus_metrics() -> Response:
    return Response(generate_latest(metrics.REGISTRY), media_type=CONTENT_TYPE_LATEST)


@app.post("/ask", response_model=AskResponse)
async def ask(payload: AskRequest, request: Request) -> AskResponse | JSONResponse:
    client = request.client.host if request.client else "unknown"
    if not app.state.limiter.allow(client):
        return JSONResponse(
            {"detail": "rate limit exceeded"},
            status_code=429,
            headers={"retry-after": "60"},
        )

    started = time.perf_counter()
    top_k = payload.top_k or settings.top_k

    retrieval_started = time.perf_counter()
    with tracer.start_as_current_span("rag.retrieve") as span:
        span.set_attribute("rag.top_k", top_k)
        span.set_attribute("rag.query_length", len(payload.query))
        chunks = app.state.retriever.search(payload.query, top_k)
        span.set_attribute("rag.matches", len(chunks))
        if chunks:
            span.set_attribute("rag.top_score", round(chunks[0].score, 4))
            span.set_attribute(
                "rag.sources", ",".join(chunk.title for chunk in chunks[:5])
            )
    retrieval_seconds = time.perf_counter() - retrieval_started
    metrics.rag_retrieval_duration_seconds.observe(retrieval_seconds)

    if chunks:
        metrics.rag_retrieved_score.observe(chunks[0].score)
    else:
        metrics.rag_empty_retrieval_total.inc()

    answer_started = time.perf_counter()
    with tracer.start_as_current_span("rag.generate") as span:
        span.set_attribute("llm.provider", app.state.llm.name)
        span.set_attribute("llm.model", settings.llm_model)
        completion = app.state.llm.complete(payload.query, chunks)
        span.set_attribute("llm.input_tokens", completion.input_tokens)
        span.set_attribute("llm.output_tokens", completion.output_tokens)
    answer_seconds = time.perf_counter() - answer_started
    metrics.rag_answer_duration_seconds.observe(answer_seconds)

    provider = app.state.llm.name
    model = settings.llm_model
    metrics.llm_tokens_total.labels(provider, model, "input").inc(completion.input_tokens)
    metrics.llm_tokens_total.labels(provider, model, "output").inc(
        completion.output_tokens
    )
    cost = (
        completion.input_tokens / 1000 * settings.llm_input_cost_per_1k
        + completion.output_tokens / 1000 * settings.llm_output_cost_per_1k
    )
    metrics.llm_cost_usd_total.labels(provider, model).inc(cost)

    latency_ms = int((time.perf_counter() - started) * 1000)
    logger.info(
        "answered query",
        extra={
            "retrieval_ms": round(retrieval_seconds * 1000, 2),
            "answer_ms": round(answer_seconds * 1000, 2),
            "latency_ms": latency_ms,
            "matches": len(chunks),
            "top_score": round(chunks[0].score, 4) if chunks else None,
            "input_tokens": completion.input_tokens,
            "output_tokens": completion.output_tokens,
        },
    )

    return AskResponse(
        answer=completion.text,
        sources=[
            Source(title=chunk.title, score=round(chunk.score, 4)) for chunk in chunks
        ],
        latency_ms=latency_ms,
    )


@app.post("/ingest")
async def ingest() -> JSONResponse:
    """Trigger indexing.

    In GCP the indexer is a Cloud Run Job so a large ingest cannot consume
    API capacity or be killed by a request timeout. This endpoint reports
    how to start it rather than doing the work inline.
    """
    from worker.indexer.main import index_path

    started = time.perf_counter()
    result = index_path(settings.data_path)
    duration = time.perf_counter() - started
    metrics.ingest_duration_seconds.observe(duration)
    return JSONResponse(
        {
            "indexed_documents": result.documents,
            "indexed_chunks": result.chunks,
            "skipped_documents": result.skipped,
            "duration_ms": int(duration * 1000),
        }
    )
