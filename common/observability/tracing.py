"""Distributed tracing.

Metrics say that p95 moved. A trace says which span moved, on which request,
with which query. The two answer different questions, which is why both are
here rather than one standing in for the other.

Spans are always created. Exporting them is what the endpoint controls: with
OTEL_EXPORTER_OTLP_ENDPOINT unset, the provider runs without an exporter and
the spans are dropped. That keeps the trace id available for log correlation
in every environment, including unit tests and a laptop with no collector
running, and means nothing fails when the collector is absent.
"""

from __future__ import annotations

import logging

from opentelemetry import trace
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.trace.sampling import ALWAYS_ON, ParentBased, TraceIdRatioBased

logger = logging.getLogger("jenie.tracing")

_configured = False


def configure_tracing(
    service_name: str,
    environment: str,
    endpoint: str | None = None,
    sample_ratio: float = 1.0,
) -> None:
    """Install the global tracer provider. Safe to call more than once."""
    global _configured
    if _configured:
        return

    resource = Resource.create(
        {
            "service.name": service_name,
            "deployment.environment": environment,
        }
    )

    # ParentBased keeps a trace whole: once a request is sampled, every span
    # beneath it is kept, so a sampled trace is never missing its middle.
    sampler = (
        ALWAYS_ON
        if sample_ratio >= 1.0
        else ParentBased(root=TraceIdRatioBased(sample_ratio))
    )

    provider = TracerProvider(resource=resource, sampler=sampler)

    if endpoint:
        try:
            from opentelemetry.exporter.otlp.proto.http.trace_exporter import (
                OTLPSpanExporter,
            )

            provider.add_span_processor(
                BatchSpanProcessor(OTLPSpanExporter(endpoint=f"{endpoint}/v1/traces"))
            )
            logger.info("tracing exporter enabled", extra={"endpoint": endpoint})
        except Exception:
            # A collector that is unreachable must not stop the service from
            # starting. Spans are still created and still correlate the logs.
            logger.warning("tracing exporter unavailable", exc_info=True)

    trace.set_tracer_provider(provider)
    _configured = True


def shutdown_tracing(timeout_millis: int = 5000) -> None:
    """Flush pending spans and stop the provider.

    BatchSpanProcessor exports on a timer. A long-running service reaches
    that timer; a batch job that finishes in under a second exits first and
    its spans are lost, which is why the indexer calls this before it
    returns. Harmless when tracing was never configured.
    """
    provider = trace.get_tracer_provider()
    flush = getattr(provider, "force_flush", None)
    if flush is not None:
        flush(timeout_millis)
    shutdown = getattr(provider, "shutdown", None)
    if shutdown is not None:
        shutdown()


def get_tracer(name: str) -> trace.Tracer:
    return trace.get_tracer(name)


def current_trace_context() -> dict[str, str]:
    """Trace and span id of the active span, for attaching to a log record.

    Returns an empty mapping when nothing is being traced, so callers can
    splat it into a log's extra without branching.
    """
    span = trace.get_current_span()
    context = span.get_span_context()
    if not context.is_valid:
        return {}
    return {
        "trace_id": format(context.trace_id, "032x"),
        "span_id": format(context.span_id, "016x"),
    }
