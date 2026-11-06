#!/usr/bin/env python3
"""Retrieval evaluation.

Runs a fixed query set against a running API and reports whether the document
that should answer each question appears in the returned sources, together
with latency. It exits non-zero when the pass rate falls below the threshold,
so the same script works as a local check and as a CI gate after a deploy.

What this measures is retrieval quality, which is the part of the pipeline
that the platform controls. It deliberately does not score the wording of the
generated answer: with the mock provider that would only measure the mock.

    python scripts/eval.py --base-url http://localhost:8000
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

DEFAULT_QUERIES = Path(__file__).with_name("eval_queries.json")


def ask(base_url: str, query: str, top_k: int, timeout: float) -> tuple[dict, float]:
    payload = json.dumps({"query": query, "top_k": top_k}).encode("utf-8")
    request = urllib.request.Request(
        f"{base_url.rstrip('/')}/ask",
        data=payload,
        headers={"content-type": "application/json"},
        method="POST",
    )
    started = time.perf_counter()
    with urllib.request.urlopen(request, timeout=timeout) as response:
        body = json.loads(response.read())
    return body, (time.perf_counter() - started) * 1000


def reciprocal_rank(sources: list[dict], expected: str) -> float:
    for position, source in enumerate(sources, start=1):
        if source.get("title") == expected:
            return 1.0 / position
    return 0.0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="http://localhost:8000")
    parser.add_argument("--queries", type=Path, default=DEFAULT_QUERIES)
    parser.add_argument("--top-k", type=int, default=5)
    parser.add_argument("--timeout", type=float, default=20.0)
    parser.add_argument(
        "--min-pass-rate",
        type=float,
        default=0.8,
        help="Fail the run when fewer than this fraction of queries hit.",
    )
    parser.add_argument(
        "--max-p95-ms",
        type=float,
        default=2000.0,
        help="Fail the run when p95 end to end latency exceeds this.",
    )
    parser.add_argument("--json", action="store_true", help="Emit JSON only.")
    args = parser.parse_args()

    cases = json.loads(args.queries.read_text(encoding="utf-8"))
    results = []

    for case in cases:
        try:
            body, latency_ms = ask(args.base_url, case["query"], args.top_k, args.timeout)
        except (urllib.error.URLError, TimeoutError) as exc:
            print(f"request failed: {exc}", file=sys.stderr)
            return 2

        sources = body.get("sources", [])
        rank = reciprocal_rank(sources, case["expected_title"])
        results.append(
            {
                "query": case["query"],
                "expected": case["expected_title"],
                "hit": rank > 0.0,
                "reciprocal_rank": round(rank, 4),
                "top_source": sources[0]["title"] if sources else None,
                "top_score": sources[0]["score"] if sources else None,
                "server_latency_ms": body.get("latency_ms"),
                "client_latency_ms": round(latency_ms, 2),
            }
        )

    hits = sum(1 for item in results if item["hit"])
    pass_rate = hits / len(results)
    mrr = statistics.fmean(item["reciprocal_rank"] for item in results)
    latencies = sorted(item["client_latency_ms"] for item in results)
    p95 = latencies[min(len(latencies) - 1, int(len(latencies) * 0.95))]

    summary = {
        "queries": len(results),
        "hits": hits,
        "pass_rate": round(pass_rate, 4),
        "mrr": round(mrr, 4),
        "p50_latency_ms": round(statistics.median(latencies), 2),
        "p95_latency_ms": round(p95, 2),
    }

    failed = pass_rate < args.min_pass_rate or p95 > args.max_p95_ms

    if args.json:
        print(json.dumps({"summary": summary, "results": results}, indent=2))
    else:
        print(f"{'result':<7} {'rr':<6} {'ms':<8} query")
        print("-" * 78)
        for item in results:
            mark = "hit" if item["hit"] else "MISS"
            print(
                f"{mark:<7} {item['reciprocal_rank']:<6.2f} "
                f"{item['client_latency_ms']:<8.0f} {item['query'][:48]}"
            )
            if not item["hit"]:
                print(
                    f"{'':<7} expected {item['expected']!r}, "
                    f"top was {item['top_source']!r}"
                )
        print("-" * 78)
        print(
            f"pass rate {summary['pass_rate']:.0%}  "
            f"mrr {summary['mrr']:.3f}  "
            f"p50 {summary['p50_latency_ms']:.0f} ms  "
            f"p95 {summary['p95_latency_ms']:.0f} ms"
        )
        print("FAILED" if failed else "PASSED")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
