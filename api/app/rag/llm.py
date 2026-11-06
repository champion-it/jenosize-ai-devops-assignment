"""LLM providers.

The provider is chosen with LLM_PROVIDER and the rest of the application
only sees the ``LLMProvider`` interface. That is what makes switching
between a mock, Vertex AI and OpenAI a configuration change rather than a
code change, and it is why the mock is a legitimate default rather than a
shortcut: the surrounding platform, which is what this assignment is about,
behaves identically either way.

Every provider reports token usage so llm_tokens_total and
llm_cost_usd_total are populated whichever backend is active.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass

from api.app.rag.retriever import RetrievedChunk

MAX_CONTEXT_CHARS = 4000


@dataclass(frozen=True)
class Completion:
    text: str
    input_tokens: int
    output_tokens: int


def estimate_tokens(text: str) -> int:
    """Approximate token count.

    Roughly four characters per token, which is close enough for a cost
    signal. A real provider reports exact usage and that value is used
    instead when available.
    """
    return max(1, len(text) // 4)


def build_prompt(query: str, chunks: list[RetrievedChunk]) -> str:
    context = []
    budget = MAX_CONTEXT_CHARS
    for chunk in chunks:
        snippet = chunk.content[:budget]
        if not snippet:
            break
        label = f"{chunk.title} / {chunk.heading}" if chunk.heading else chunk.title
        context.append(f"[{label}]\n{snippet}")
        budget -= len(snippet)

    joined = "\n\n".join(context) if context else "No relevant documents found."
    return (
        "Answer the question using only the context below. "
        "If the context does not contain the answer, say so.\n\n"
        f"Context:\n{joined}\n\nQuestion: {query}\nAnswer:"
    )


class LLMProvider(ABC):
    def __init__(self, model: str) -> None:
        self.model = model

    @property
    @abstractmethod
    def name(self) -> str: ...

    @abstractmethod
    def complete(self, query: str, chunks: list[RetrievedChunk]) -> Completion: ...


class MockLLMProvider(LLMProvider):
    """Extractive answer assembled from the retrieved chunks.

    No network call and no API key. The answer is grounded in real retrieved
    text, so a retrieval regression is still visible in the response and in
    the evaluation suite.
    """

    @property
    def name(self) -> str:
        return "mock"

    def complete(self, query: str, chunks: list[RetrievedChunk]) -> Completion:
        prompt = build_prompt(query, chunks)

        if not chunks:
            answer = (
                "I could not find anything in the knowledge base that answers "
                "this question."
            )
        else:
            best = chunks[0]
            lead = " ".join(best.content.split())
            if len(lead) > 600:
                lead = lead[:600].rsplit(" ", 1)[0] + "..."
            citations = ", ".join(dict.fromkeys(chunk.title for chunk in chunks[:3]))
            answer = f"{lead}\n\nBased on: {citations}."

        return Completion(
            text=answer,
            input_tokens=estimate_tokens(prompt),
            output_tokens=estimate_tokens(answer),
        )


class VertexLLMProvider(LLMProvider):
    """Vertex AI generative model. Imported lazily."""

    @property
    def name(self) -> str:
        return "vertex"

    def complete(self, query: str, chunks: list[RetrievedChunk]) -> Completion:
        try:
            from vertexai.generative_models import GenerativeModel
        except ImportError as exc:  # pragma: no cover - optional dependency
            raise RuntimeError(
                "LLM_PROVIDER=vertex requires google-cloud-aiplatform and "
                "application default credentials."
            ) from exc

        prompt = build_prompt(query, chunks)
        response = GenerativeModel(self.model).generate_content(prompt)
        usage = getattr(response, "usage_metadata", None)
        return Completion(
            text=response.text,
            input_tokens=getattr(usage, "prompt_token_count", None)
            or estimate_tokens(prompt),
            output_tokens=getattr(usage, "candidates_token_count", None)
            or estimate_tokens(response.text),
        )


class OpenAILLMProvider(LLMProvider):
    """OpenAI chat completion. Imported lazily."""

    @property
    def name(self) -> str:
        return "openai"

    def complete(self, query: str, chunks: list[RetrievedChunk]) -> Completion:
        try:
            from openai import OpenAI
        except ImportError as exc:  # pragma: no cover - optional dependency
            raise RuntimeError(
                "LLM_PROVIDER=openai requires the openai package and " "OPENAI_API_KEY."
            ) from exc

        prompt = build_prompt(query, chunks)
        response = OpenAI().chat.completions.create(
            model=self.model,
            messages=[{"role": "user", "content": prompt}],
        )
        usage = response.usage
        return Completion(
            text=response.choices[0].message.content or "",
            input_tokens=usage.prompt_tokens if usage else estimate_tokens(prompt),
            output_tokens=usage.completion_tokens if usage else 0,
        )


def build_llm_provider(provider: str, model: str) -> LLMProvider:
    providers: dict[str, type[LLMProvider]] = {
        "mock": MockLLMProvider,
        "vertex": VertexLLMProvider,
        "openai": OpenAILLMProvider,
    }
    if provider not in providers:
        raise ValueError(
            f"Unknown LLM_PROVIDER {provider!r}. Expected one of {sorted(providers)}."
        )
    return providers[provider](model)
