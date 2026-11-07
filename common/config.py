"""Runtime configuration.

Every value is read from the environment so that the same image runs
unchanged in docker-compose and in both cluster namespaces. Secrets are
read from Secrets Manager in the cluster and from a local .env file in
development.
"""

from __future__ import annotations

from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    service_name: str = "jenie-api"
    environment: str = "local"
    log_level: str = "INFO"

    database_url: str = "postgresql://jenie:jenie@localhost:5432/jenie"
    # Seconds a request waits for a pooled connection before failing.
    database_acquire_timeout: float = 5.0
    redis_url: str | None = None

    embedding_provider: str = "hashing"
    embedding_dim: int = 768

    llm_provider: str = "mock"
    llm_model: str = "mock-1"
    llm_input_cost_per_1k: float = 0.00015
    llm_output_cost_per_1k: float = 0.0006

    # Unset means spans are created but not exported. See tracing.py.
    otel_exporter_otlp_endpoint: str | None = None
    otel_sample_ratio: float = 1.0

    top_k: int = 5
    rate_limit_per_minute: int = 60
    data_path: str = "/data"

    chunk_size: int = 900
    chunk_overlap: int = 150


@lru_cache
def get_settings() -> Settings:
    return Settings()
