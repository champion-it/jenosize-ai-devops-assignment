"""Indexer.

Reads markdown documents, splits them into chunks, embeds each chunk and
upserts the result into pgvector.

The run is idempotent: a document whose content hash is unchanged is
skipped, so rerunning the job after a partial failure is safe and cheap.
That property is what lets the index be rebuilt from /data as part of
disaster recovery.
"""

from __future__ import annotations

import argparse
import hashlib
import logging
import sys
import time
from dataclasses import dataclass
from pathlib import Path

from common.chunker import split_markdown
from common.config import get_settings
from common.db import Database, to_vector_literal
from common.embeddings import build_embedding_provider
from common.observability import metrics
from common.observability.logging import configure_logging
from common.observability.tracing import (
    configure_tracing,
    get_tracer,
    shutdown_tracing,
)

logger = logging.getLogger("jenie.indexer")

UPSERT_DOCUMENT_SQL = """
INSERT INTO documents (path, title, content_hash)
VALUES (%(path)s, %(title)s, %(hash)s)
ON CONFLICT (path) DO UPDATE
    SET title = EXCLUDED.title,
        content_hash = EXCLUDED.content_hash,
        indexed_at = now()
RETURNING id
"""

INSERT_CHUNK_SQL = """
INSERT INTO chunks (document_id, ordinal, heading, content, embedding, model)
VALUES (%(document_id)s, %(ordinal)s, %(heading)s, %(content)s,
        %(embedding)s::vector, %(model)s)
ON CONFLICT (document_id, ordinal) DO UPDATE
    SET heading = EXCLUDED.heading,
        content = EXCLUDED.content,
        embedding = EXCLUDED.embedding,
        model = EXCLUDED.model
"""


@dataclass
class IndexResult:
    documents: int = 0
    chunks: int = 0
    skipped: int = 0


def extract_title(text: str, fallback: str) -> str:
    for line in text.splitlines():
        if line.startswith("# "):
            return line[2:].strip()
    return fallback


def index_path(path: str, force: bool = False) -> IndexResult:
    settings = get_settings()
    tracer = get_tracer("jenie.indexer")
    database = Database(settings.database_url, settings.embedding_dim, max_size=4)
    database.open()
    try:
        database.migrate()
        embeddings = build_embedding_provider(
            settings.embedding_provider, settings.embedding_dim
        )
        result = IndexResult()
        files = sorted(Path(path).glob("**/*.md"))
        if not files:
            logger.warning("no markdown documents found", extra={"path": path})
            return result

        for file in files:
            with tracer.start_as_current_span("index.document") as span:
                span.set_attribute("document.path", str(file))
                text = file.read_text(encoding="utf-8")
                content_hash = hashlib.sha256(text.encode("utf-8")).hexdigest()

                with database.connection() as conn:
                    if not force:
                        row = conn.execute(
                            "SELECT content_hash FROM documents WHERE path = %s",
                            (str(file),),
                        ).fetchone()
                        if row and row[0] == content_hash:
                            result.skipped += 1
                            metrics.ingest_documents_total.labels("skipped").inc()
                            continue

                    title = extract_title(text, file.stem.replace("-", " ").title())
                    document_id = conn.execute(
                        UPSERT_DOCUMENT_SQL,
                        {"path": str(file), "title": title, "hash": content_hash},
                    ).fetchone()[0]

                    # Chunk ordinals are rewritten below; clearing first stops a
                    # shortened document from leaving orphaned tail chunks behind.
                    conn.execute(
                        "DELETE FROM chunks WHERE document_id = %s", (document_id,)
                    )

                    pieces = split_markdown(
                        text, settings.chunk_size, settings.chunk_overlap
                    )
                    vectors = embeddings.embed([piece.content for piece in pieces])

                    for piece, vector in zip(pieces, vectors, strict=False):
                        conn.execute(
                            INSERT_CHUNK_SQL,
                            {
                                "document_id": document_id,
                                "ordinal": piece.ordinal,
                                "heading": piece.heading,
                                "content": piece.content,
                                "embedding": to_vector_literal(vector),
                                "model": embeddings.name,
                            },
                        )
                    conn.commit()

                result.documents += 1
                result.chunks += len(pieces)
                metrics.ingest_documents_total.labels("indexed").inc()
                logger.info(
                    "indexed document",
                    extra={"path": str(file), "title": title, "chunks": len(pieces)},
                )

        return result
    finally:
        database.close()


def main() -> int:
    settings = get_settings()
    configure_logging("jenie-worker", settings.environment, settings.log_level)

    parser = argparse.ArgumentParser(description="Index markdown documents.")
    parser.add_argument("--path", default=settings.data_path)
    parser.add_argument(
        "--force",
        action="store_true",
        help="Reindex documents even when the content hash is unchanged.",
    )
    args = parser.parse_args()

    configure_tracing(
        "jenie-worker",
        settings.environment,
        settings.otel_exporter_otlp_endpoint,
        settings.otel_sample_ratio,
    )

    started = time.perf_counter()
    try:
        result = index_path(args.path, force=args.force)
    except Exception:
        logger.exception("indexing run failed", extra={"path": args.path})
        return 1
    finally:
        # The job exits in well under the batch export interval, so the spans
        # have to be flushed explicitly or they never leave the process.
        shutdown_tracing()

    duration = time.perf_counter() - started
    metrics.ingest_duration_seconds.observe(duration)
    logger.info(
        "indexing run complete",
        extra={
            "documents": result.documents,
            "chunks": result.chunks,
            "skipped": result.skipped,
            "duration_ms": int(duration * 1000),
        },
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
