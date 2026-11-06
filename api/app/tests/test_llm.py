import pytest

from api.app.rag.llm import MockLLMProvider, build_llm_provider, build_prompt
from api.app.rag.retriever import RetrievedChunk


def chunk(title: str, content: str, score: float = 0.9) -> RetrievedChunk:
    return RetrievedChunk(
        title=title, path=f"/data/{title}.md", heading="", content=content, score=score
    )


def test_answer_is_grounded_in_the_best_chunk():
    provider = MockLLMProvider("mock-1")
    completion = provider.complete(
        "how do I reset my password",
        [chunk("Password Reset", "Open the self service portal and request a link.")],
    )
    assert "self service portal" in completion.text
    assert "Password Reset" in completion.text


def test_no_matches_produces_an_explicit_miss():
    provider = MockLLMProvider("mock-1")
    completion = provider.complete("unrelated question", [])
    assert "could not find" in completion.text.lower()


def test_token_counts_are_always_reported():
    provider = MockLLMProvider("mock-1")
    completion = provider.complete("q", [chunk("A", "body text")])
    assert completion.input_tokens > 0
    assert completion.output_tokens > 0


def test_prompt_stays_within_the_context_budget():
    chunks = [chunk(f"Doc {i}", "x" * 3000) for i in range(5)]
    prompt = build_prompt("question", chunks)
    assert len(prompt) < 4600


def test_unknown_provider_is_rejected():
    with pytest.raises(ValueError, match="Unknown LLM_PROVIDER"):
        build_llm_provider("nope", "model")
