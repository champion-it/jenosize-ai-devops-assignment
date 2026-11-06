"""Structured JSON logging.

One JSON object per line keeps the output readable by Cloud Logging without
a parser, and by ``jq`` during local development. The request id is carried
on the record so a single request can be followed across log lines.
"""

from __future__ import annotations

import json
import logging
import sys
from datetime import UTC, datetime

RESERVED = set(logging.LogRecord("", 0, "", 0, "", (), None).__dict__) | {
    "asctime",
    "message",
    "taskName",
}


class JsonFormatter(logging.Formatter):
    def __init__(self, service: str, environment: str) -> None:
        super().__init__()
        self.service = service
        self.environment = environment

    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "timestamp": datetime.fromtimestamp(record.created, tz=UTC).isoformat(),
            # Cloud Logging promotes this field to the entry severity.
            "severity": record.levelname,
            "message": record.getMessage(),
            "logger": record.name,
            "service": self.service,
            "environment": self.environment,
        }
        for key, value in record.__dict__.items():
            if key not in RESERVED:
                payload[key] = value
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload, default=str)


def configure_logging(service: str, environment: str, level: str = "INFO") -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter(service, environment))

    root = logging.getLogger()
    root.handlers.clear()
    root.addHandler(handler)
    root.setLevel(level.upper())

    # uvicorn installs its own handlers; route them through this one so that
    # startup and error lines are JSON too.
    for name in ("uvicorn", "uvicorn.error"):
        logger = logging.getLogger(name)
        logger.handlers.clear()
        logger.propagate = True

    # The request middleware already logs every request with timing and a
    # request id. uvicorn's access log would duplicate that with less detail,
    # and clearing its handlers is not enough once propagation is on.
    access = logging.getLogger("uvicorn.access")
    access.handlers.clear()
    access.propagate = False
    access.disabled = True
