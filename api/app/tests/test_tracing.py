"""Tracing behaviour that the rest of the system relies on."""

from __future__ import annotations

from opentelemetry import trace

from common.observability.tracing import (
    configure_tracing,
    current_trace_context,
    get_tracer,
)


def test_configure_without_an_endpoint_does_not_raise():
    # A laptop or a CI runner has no collector. Tracing must not be a reason
    # the service fails to start.
    configure_tracing("jenie-test", "test", endpoint=None)


def test_no_context_outside_a_span():
    assert current_trace_context() == {}


def test_trace_and_span_ids_are_exposed_inside_a_span():
    configure_tracing("jenie-test", "test", endpoint=None)
    with get_tracer("test").start_as_current_span("unit"):
        context = current_trace_context()
        assert set(context) == {"trace_id", "span_id"}
        assert len(context["trace_id"]) == 32
        assert len(context["span_id"]) == 16
        int(context["trace_id"], 16)


def test_child_span_shares_the_trace_id():
    configure_tracing("jenie-test", "test", endpoint=None)
    tracer = get_tracer("test")
    with tracer.start_as_current_span("parent"):
        parent = current_trace_context()
        with tracer.start_as_current_span("child"):
            child = current_trace_context()
    assert parent["trace_id"] == child["trace_id"]
    assert parent["span_id"] != child["span_id"]


def test_configure_is_idempotent():
    configure_tracing("jenie-test", "test", endpoint=None)
    first = trace.get_tracer_provider()
    configure_tracing("jenie-other", "test", endpoint=None)
    assert trace.get_tracer_provider() is first


def test_shutdown_is_safe_to_call():
    # A batch job calls this in a finally block; it must not raise even when
    # tracing was never configured or has already been shut down.
    from common.observability.tracing import shutdown_tracing

    shutdown_tracing()
