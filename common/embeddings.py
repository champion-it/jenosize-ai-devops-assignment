"""Embedding providers.

Two providers are available and selected with EMBEDDING_PROVIDER:

``hashing``
    A deterministic local embedding built from hashed word unigrams and
    bigrams with sublinear term weighting. It needs no model download, no
    GPU and no network, so ``docker compose up`` works offline and CI runs
    in seconds. Retrieval quality on a small, keyword-oriented knowledge
    base is good enough for the evaluation suite to be meaningful.

``vertex``
    Vertex AI text embeddings. Used to show the same pipeline running
    against a managed model. It is not the default because the assignment
    does not require a paid API and determinism keeps the eval stable.

Both return L2-normalised vectors of the same dimension, so the vector
store and the retriever do not care which one produced them.
"""

from __future__ import annotations

import hashlib
import math
import re
from abc import ABC, abstractmethod
from collections import Counter

TOKEN_RE = re.compile(r"[a-z0-9]+")

# Function words carry no topic. Without this list, every query and every
# document share "how", "do", "the" and "is", and cosine similarity ends up
# ranking on those instead of on the words that tell one document from
# another.
STOPWORDS = frozenset(
    """
    a about all also an and any are as at be been being but by can cannot
    could did do does doing done for from get give got had has have having he
    her here hers him his how i if in into is it its just me more most much my
    need no not of on once one only or other our out over own same she should
    so some such than that the their them then there these they this those to
    too until up us use used using very was we were what when where which
    while who whom why will with would you your
    """.split()
)


def _tokenize(text: str) -> list[str]:
    words = [word for word in TOKEN_RE.findall(text.lower()) if word not in STOPWORDS]
    # Bigrams are formed after stopwords are removed, so "reset my password"
    # yields "reset_password". The phrase survives the words that were
    # dropped, which is what makes a multi-word concept outrank two documents
    # that each contain only one half of it.
    bigrams = [f"{a}_{b}" for a, b in zip(words, words[1:], strict=False)]
    return words + bigrams


class EmbeddingProvider(ABC):
    """Interface every embedding backend implements."""

    def __init__(self, dim: int) -> None:
        self.dim = dim

    @abstractmethod
    def embed(self, texts: list[str]) -> list[list[float]]:
        """Return one vector per input text."""

    @property
    @abstractmethod
    def name(self) -> str:
        """Identifier recorded alongside stored vectors."""


class HashingEmbeddingProvider(EmbeddingProvider):
    """Deterministic, dependency-free lexical embedding."""

    @property
    def name(self) -> str:
        return f"hashing-{self.dim}"

    def _bucket(self, token: str) -> tuple[int, float]:
        digest = hashlib.blake2b(token.encode("utf-8"), digest_size=8).digest()
        value = int.from_bytes(digest, "big")
        # The lowest bit picks the sign, which keeps collisions from
        # systematically inflating similarity between unrelated documents.
        sign = 1.0 if value & 1 else -1.0
        return (value >> 1) % self.dim, sign

    def embed(self, texts: list[str]) -> list[list[float]]:
        return [self._embed_one(text) for text in texts]

    def _embed_one(self, text: str) -> list[float]:
        vector = [0.0] * self.dim
        counts = Counter(_tokenize(text))
        for token, count in counts.items():
            index, sign = self._bucket(token)
            # Sublinear term frequency: a word repeated ten times should not
            # dominate a word that appears twice.
            vector[index] += sign * (1.0 + math.log(count))

        norm = math.sqrt(sum(value * value for value in vector))
        if norm == 0.0:
            return vector
        return [value / norm for value in vector]


class VertexEmbeddingProvider(EmbeddingProvider):
    """Vertex AI text embeddings.

    Imported lazily so the dependency is only needed when the provider is
    actually selected.
    """

    def __init__(self, dim: int, model: str = "gemini-embedding-001") -> None:
        super().__init__(dim)
        self.model = model

    @property
    def name(self) -> str:
        return f"vertex-{self.model}"

    def embed(self, texts: list[str]) -> list[list[float]]:
        try:
            from vertexai.language_models import TextEmbeddingModel
        except ImportError as exc:  # pragma: no cover - optional dependency
            raise RuntimeError(
                "EMBEDDING_PROVIDER=vertex requires the google-cloud-aiplatform "
                "package and application default credentials."
            ) from exc

        model = TextEmbeddingModel.from_pretrained(self.model)
        vectors = []
        # Vertex caps the number of instances per request.
        for start in range(0, len(texts), 32):
            batch = model.get_embeddings(texts[start : start + 32])
            vectors.extend(self._normalise(item.values) for item in batch)
        return vectors

    def _normalise(self, values: list[float]) -> list[float]:
        trimmed = values[: self.dim]
        norm = math.sqrt(sum(value * value for value in trimmed))
        return trimmed if norm == 0.0 else [value / norm for value in trimmed]


def build_embedding_provider(provider: str, dim: int) -> EmbeddingProvider:
    providers: dict[str, type[EmbeddingProvider]] = {
        "hashing": HashingEmbeddingProvider,
        "vertex": VertexEmbeddingProvider,
    }
    if provider not in providers:
        raise ValueError(
            f"Unknown EMBEDDING_PROVIDER {provider!r}. "
            f"Expected one of {sorted(providers)}."
        )
    return providers[provider](dim)
