import pytest

from common.chunker import split_markdown

DOCUMENT = """# Title

Intro paragraph.

## First section

First body.

## Second section

Second body.
"""


def test_sections_become_separate_chunks():
    chunks = split_markdown(DOCUMENT, chunk_size=900, overlap=100)
    headings = [chunk.heading for chunk in chunks]
    assert "First section" in headings
    assert "Second section" in headings


def test_ordinals_are_contiguous():
    chunks = split_markdown(DOCUMENT, chunk_size=900, overlap=100)
    assert [chunk.ordinal for chunk in chunks] == list(range(len(chunks)))


def test_long_section_is_windowed():
    text = "# T\n\n## S\n\n" + ("word " * 600)
    chunks = split_markdown(text, chunk_size=400, overlap=50)
    assert len(chunks) > 1
    assert all(len(chunk.content) <= 400 for chunk in chunks)


def test_document_without_headings_still_chunks():
    chunks = split_markdown("plain text with no heading", chunk_size=900, overlap=100)
    assert len(chunks) == 1
    assert chunks[0].heading == ""


def test_overlap_must_be_smaller_than_chunk_size():
    with pytest.raises(ValueError, match="chunk_overlap"):
        split_markdown(DOCUMENT, chunk_size=100, overlap=100)
