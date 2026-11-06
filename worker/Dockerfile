# Build context is the repository root. See api/Dockerfile.
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

RUN useradd --create-home --uid 10001 appuser

COPY --chown=appuser:appuser common/ ./common/
COPY --chown=appuser:appuser worker/ ./worker/

USER appuser

ENTRYPOINT ["python", "-m", "worker.indexer.main"]
CMD ["--path", "/data"]
