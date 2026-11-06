"""Logs must carry the trace id, or correlating them is manual work."""

from __future__ import annotations

import json
import logging

from common.observability.logging import JsonFormatter
from common.observability.tracing import configure_tracing, get_tracer


def render(record: logging.LogRecord) -> dict:
    return json.loads(JsonFormatter("jenie-test", "test").format(record))


def make_record(**extra) -> logging.LogRecord:
    record = logging.LogRecord("jenie.test", logging.INFO, __file__, 1, "hello", (), None)
    for key, value in extra.items():
        setattr(record, key, value)
    return record


def test_log_is_json_with_the_expected_envelope():
    payload = render(make_record())
    assert payload["message"] == "hello"
    assert payload["severity"] == "INFO"
    assert payload["service"] == "jenie-test"


def test_extra_fields_are_preserved():
    payload = render(make_record(request_id="abc", latency_ms=12.3))
    assert payload["request_id"] == "abc"
    assert payload["latency_ms"] == 12.3


def test_trace_id_is_attached_inside_a_span():
    configure_tracing("jenie-test", "test", endpoint=None)
    with get_tracer("test").start_as_current_span("unit"):
        payload = render(make_record())
    assert len(payload["trace_id"]) == 32
    assert len(payload["span_id"]) == 16


def test_no_trace_fields_outside_a_span():
    payload = render(make_record())
    assert "trace_id" not in payload
