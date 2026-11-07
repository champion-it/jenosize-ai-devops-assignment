# Build context is the repository root so the api and the worker can share
# the common package without vendoring it twice.
FROM python:3.12-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

FROM base AS deps
COPY requirements.txt .
RUN pip install --prefix=/install -r requirements.txt

FROM base AS runtime
COPY --from=deps /install /usr/local

# Run as an unprivileged user. Combined with a read-only root filesystem in
# Kubernetes this removes the easiest container escape paths.
RUN useradd --create-home --uid 10001 appuser

COPY --chown=appuser:appuser common/ ./common/
COPY --chown=appuser:appuser api/ ./api/
COPY --chown=appuser:appuser worker/ ./worker/

USER appuser
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/healthz').status==200 else 1)"

# A graceful shutdown window lets in-flight requests finish when the
# orchestrator sends SIGTERM during a rollout.
CMD ["uvicorn", "api.app.main:app", \
     "--host", "0.0.0.0", "--port", "8000", \
     "--timeout-graceful-shutdown", "20", \
     "--no-access-log"]
