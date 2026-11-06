import math

import pytest

from common.embeddings import HashingEmbeddingProvider, build_embedding_provider


@pytest.fixture
def provider() -> HashingEmbeddingProvider:
    return HashingEmbeddingProvider(dim=128)


def test_vectors_have_the_configured_dimension(provider):
    [vector] = provider.embed(["how do I reset my password"])
    assert len(vector) == 128


def test_vectors_are_unit_length(provider):
    [vector] = provider.embed(["multi factor authentication enrolment"])
    assert math.isclose(math.sqrt(sum(v * v for v in vector)), 1.0, rel_tol=1e-6)


def test_embedding_is_deterministic(provider):
    first = provider.embed(["printer queue stuck"])
    second = provider.embed(["printer queue stuck"])
    assert first == second


def test_related_text_scores_higher_than_unrelated(provider):
    query, related, unrelated = provider.embed(
        [
            "how do I reset a forgotten password",
            "resetting a forgotten password from the self service portal",
            "economy class flights under six hours are the travel standard",
        ]
    )
    assert _cosine(query, related) > _cosine(query, unrelated)


def test_empty_text_produces_a_zero_vector(provider):
    [vector] = provider.embed([""])
    assert all(value == 0.0 for value in vector)


def test_unknown_provider_is_rejected():
    with pytest.raises(ValueError, match="Unknown EMBEDDING_PROVIDER"):
        build_embedding_provider("does-not-exist", 128)


def _cosine(a: list[float], b: list[float]) -> float:
    return sum(x * y for x, y in zip(a, b, strict=False))
