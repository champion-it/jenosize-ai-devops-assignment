"""Retrieval quality on the real knowledge base.

This runs the same ranking the API performs, without a database, so an
embedding regression is caught by the unit suite rather than only by the
integration evaluation. The queries are the ones in
scripts/eval_queries.json.

The assertion is recall at k rather than "the expected document ranks
first". Every retrieved chunk is placed in the prompt, so what the pipeline
depends on is the right document being in the retrieved set. Rank one is
guarded separately by the mean reciprocal rank threshold, which catches a
ranking regression without failing on a single reordering between two
documents that are both plausible answers.
"""

from __future__ import annotations

import json
import statistics
from pathlib import Path

import pytest

from common.chunker import split_markdown
from common.embeddings import HashingEmbeddingProvider
from worker.indexer.main import extract_title

ROOT = Path(__file__).resolve().parents[3]
DATA = ROOT / "data"
QUERIES = json.loads((ROOT / "scripts" / "eval_queries.json").read_text())

TOP_K = 5
MIN_MRR = 0.9
DIM = 768


@pytest.fixture(scope="module")
def index() -> list[tuple[str, list[float]]]:
    provider = HashingEmbeddingProvider(DIM)
    entries: list[tuple[str, list[float]]] = []
    for file in sorted(DATA.glob("*.md")):
        text = file.read_text(encoding="utf-8")
        title = extract_title(text, file.stem)
        pieces = split_markdown(text, chunk_size=900, overlap=150)
        vectors = provider.embed([piece.content for piece in pieces])
        entries.extend((title, vector) for vector in vectors)
    return entries


def ranked_titles(index, query: str) -> list[str]:
    provider = HashingEmbeddingProvider(DIM)
    query_vector = provider.embed([query])[0]
    scored = sorted(
        (
            (title, sum(a * b for a, b in zip(query_vector, vector, strict=True)))
            for title, vector in index
        ),
        key=lambda item: item[1],
        reverse=True,
    )
    # Collapse chunks to documents, keeping each document's best rank.
    return list(dict.fromkeys(title for title, _ in scored))


@pytest.mark.parametrize("case", QUERIES, ids=lambda case: case["expected_title"])
def test_expected_document_is_retrieved(index, case):
    titles = ranked_titles(index, case["query"])
    assert case["expected_title"] in titles[:TOP_K], (
        f"expected {case['expected_title']!r} within the top {TOP_K}, "
        f"got {titles[:TOP_K]}"
    )


def test_ranking_quality_does_not_regress(index):
    reciprocal_ranks = []
    for case in QUERIES:
        titles = ranked_titles(index, case["query"])
        position = titles.index(case["expected_title"]) + 1
        reciprocal_ranks.append(1 / position)

    mrr = statistics.fmean(reciprocal_ranks)
    assert mrr >= MIN_MRR, f"mean reciprocal rank fell to {mrr:.3f}"


def test_corpus_is_present():
    assert len(list(DATA.glob("*.md"))) >= 10
