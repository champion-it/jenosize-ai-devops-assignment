"""Postgres access and schema management.

pgvector stores the embeddings next to the document metadata, so a single
managed database covers both. That keeps one backup, one restore procedure
and one network path to secure.
"""

from __future__ import annotations

from collections.abc import Iterator
from contextlib import contextmanager

import psycopg
from psycopg_pool import ConnectionPool

SCHEMA = """
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS documents (
    id            BIGSERIAL PRIMARY KEY,
    path          TEXT NOT NULL UNIQUE,
    title         TEXT NOT NULL,
    content_hash  TEXT NOT NULL,
    indexed_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS chunks (
    id           BIGSERIAL PRIMARY KEY,
    document_id  BIGINT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    ordinal      INTEGER NOT NULL,
    heading      TEXT NOT NULL DEFAULT '',
    content      TEXT NOT NULL,
    embedding    VECTOR(%(dim)s) NOT NULL,
    model        TEXT NOT NULL,
    UNIQUE (document_id, ordinal)
);

-- HNSW rather than IVFFlat.
--
-- IVFFlat assigns vectors to lists whose centroids are computed when the
-- index is built. Building it here, before any rows exist, leaves it with no
-- usable centroids, and a probe then matches nothing: the search returns zero
-- rows while a sequential scan over the same data returns correct results.
-- Rebuilding after every ingest would be the alternative.
--
-- HNSW builds incrementally, so it is correct on an empty table and stays
-- correct as rows arrive. It costs more to build and more memory, which is
-- the right trade for a read-heavy index that is written by a batch job.
CREATE INDEX IF NOT EXISTS chunks_embedding_idx
    ON chunks USING hnsw (embedding vector_cosine_ops);
"""


class Database:
    def __init__(
        self,
        dsn: str,
        dim: int,
        min_size: int = 1,
        max_size: int = 8,
        acquire_timeout: float = 5.0,
    ) -> None:
        self.dim = dim
        # How long a request waits for a connection before giving up.
        #
        # psycopg_pool defaults to 30 seconds. With the database unreachable
        # that turns every request into a 30 second hang before it finally
        # returns 500: the caller has usually timed out by then, the latency
        # budget is spent on requests that were never going to succeed, and
        # the queue behind them grows. Failing in five seconds keeps the
        # error signal fast and honest.
        self.pool = ConnectionPool(
            dsn,
            min_size=min_size,
            max_size=max_size,
            timeout=acquire_timeout,
            open=False,
        )

    def open(self) -> None:
        self.pool.open(wait=True, timeout=30)

    def close(self) -> None:
        self.pool.close()

    @contextmanager
    def connection(self) -> Iterator[psycopg.Connection]:
        with self.pool.connection() as conn:
            yield conn

    def migrate(self) -> None:
        with self.connection() as conn:
            conn.execute(SCHEMA % {"dim": self.dim})
            conn.commit()

    def ping(self) -> bool:
        with self.connection() as conn:
            return conn.execute("SELECT 1").fetchone() is not None


def to_vector_literal(vector: list[float]) -> str:
    """Render a Python list in the text form pgvector accepts."""
    return "[" + ",".join(f"{value:.8f}" for value in vector) + "]"
