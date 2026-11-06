"""Vector retrieval over pgvector."""

from __future__ import annotations

from dataclasses import dataclass

from common.db import Database, to_vector_literal
from common.embeddings import EmbeddingProvider

# Cosine distance is in [0, 2]; similarity is 1 - distance.
#
# This floor only drops chunks with essentially no lexical overlap with the
# query. It is deliberately not a relevance threshold: measured against this
# corpus, off-topic queries score 0.07 to 0.12 while the lowest correct match
# scores 0.078, so the ranges overlap and no absolute cut-off separates them.
# Treat the score as a drift signal over time, not as per-query confidence.
# A provider with semantic embeddings gives a better separated distribution
# and would justify raising this.
SCORE_FLOOR = 0.02

SEARCH_SQL = """
SELECT d.title,
       d.path,
       c.heading,
       c.content,
       1 - (c.embedding <=> %(query)s::vector) AS score
FROM chunks c
JOIN documents d ON d.id = c.document_id
ORDER BY c.embedding <=> %(query)s::vector
LIMIT %(limit)s
"""


@dataclass(frozen=True)
class RetrievedChunk:
    title: str
    path: str
    heading: str
    content: str
    score: float


class Retriever:
    def __init__(self, database: Database, embeddings: EmbeddingProvider) -> None:
        self.database = database
        self.embeddings = embeddings

    def search(self, query: str, limit: int) -> list[RetrievedChunk]:
        vector = self.embeddings.embed([query])[0]
        literal = to_vector_literal(vector)

        with self.database.connection() as conn:
            rows = conn.execute(SEARCH_SQL, {"query": literal, "limit": limit}).fetchall()

        results = [
            RetrievedChunk(
                title=row[0],
                path=row[1],
                heading=row[2],
                content=row[3],
                score=float(row[4]),
            )
            for row in rows
        ]
        return [item for item in results if item.score >= SCORE_FLOOR]
