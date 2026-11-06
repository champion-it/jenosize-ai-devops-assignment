"""Markdown chunking.

Splits on heading boundaries first so that a chunk keeps the section it
belongs to, then falls back to a sliding window for sections that are longer
than the configured chunk size.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

HEADING_RE = re.compile(r"^(#{1,6})\s+(.*)$", re.MULTILINE)


@dataclass(frozen=True)
class Chunk:
    ordinal: int
    heading: str
    content: str


def split_markdown(text: str, chunk_size: int, overlap: int) -> list[Chunk]:
    if overlap >= chunk_size:
        raise ValueError("chunk_overlap must be smaller than chunk_size")

    sections = _split_by_heading(text)
    chunks: list[Chunk] = []
    for heading, body in sections:
        for piece in _window(body.strip(), chunk_size, overlap):
            if piece:
                chunks.append(Chunk(len(chunks), heading, piece))
    return chunks


def _split_by_heading(text: str) -> list[tuple[str, str]]:
    matches = list(HEADING_RE.finditer(text))
    if not matches:
        return [("", text)]

    sections: list[tuple[str, str]] = []
    preamble = text[: matches[0].start()].strip()
    if preamble:
        sections.append(("", preamble))

    for index, match in enumerate(matches):
        start = match.end()
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        sections.append((match.group(2).strip(), text[start:end]))
    return sections


def _window(text: str, size: int, overlap: int) -> list[str]:
    if len(text) <= size:
        return [text]

    step = size - overlap
    pieces = []
    for start in range(0, len(text), step):
        piece = text[start : start + size].strip()
        if piece:
            pieces.append(piece)
        if start + size >= len(text):
            break
    return pieces
