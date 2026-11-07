#!/usr/bin/env python3
"""Render the Prometheus alert rules into Cloud Monitoring alert policies.

Why this exists rather than writing the policies by hand:

Cloud Monitoring can evaluate PromQL directly against Managed Service for
Prometheus, but it does not evaluate recording rules. The alert expressions
in observability/alerts/rules.yml are written against recorded series like
jenie:availability_error_ratio:1h, which exist in a local Prometheus and do
not exist in GMP.

Writing the expressions a second time in Terraform would mean two
definitions of the same objective, and the one nobody looks at is the one
that silently drifts. Instead the recording rules are inlined here and the
result is committed. CI re-renders and fails if the committed file differs,
so the YAML stays the only place a threshold is edited.

    python3 scripts/render_slo_alerts.py            # write
    python3 scripts/render_slo_alerts.py --check    # fail if stale
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
RULES = ROOT / "observability" / "alerts" / "rules.yml"
OUTPUT = ROOT / "infra" / "terraform" / "modules" / "observability" / "slo_alerts.json"

# Recording rule names look like jenie:metric:window.
RECORD_RE = re.compile(r"\b[a-zA-Z_][a-zA-Z0-9_]*:[a-zA-Z0-9_:]+\b")

MAX_PASSES = 10


def collapse(expr: str) -> str:
    """One line, single-spaced. PromQL does not care; a diff does."""
    return " ".join(expr.split())


def inline(expr: str, recordings: dict[str, str]) -> str:
    """Replace recorded series with their definitions, repeatedly.

    Repeated because a recording rule may itself reference another. The pass
    limit turns a cycle into a loud failure rather than a hang.
    """
    for _ in range(MAX_PASSES):
        names = {n for n in RECORD_RE.findall(expr) if n in recordings}
        if not names:
            return expr
        # Longest first, so jenie:x:30m is not partially matched by jenie:x:3.
        for name in sorted(names, key=len, reverse=True):
            expr = expr.replace(name, f"({collapse(recordings[name])})")
    raise SystemExit(
        f"recording rules did not resolve after {MAX_PASSES} passes; " "check for a cycle"
    )


def render() -> list[dict]:
    document = yaml.safe_load(RULES.read_text())

    recordings: dict[str, str] = {}
    alerts: list[dict] = []
    for group in document["groups"]:
        for rule in group["rules"]:
            if "record" in rule:
                recordings[rule["record"]] = rule["expr"]
            elif "alert" in rule:
                alerts.append(rule)

    policies = []
    for rule in alerts:
        labels = rule.get("labels", {})
        annotations = rule.get("annotations", {})

        # Operational alerts that depend on scrape liveness have no meaning
        # on Cloud Run: there is no Prometheus target to be up or down, the
        # platform reports instance health itself.
        if rule["alert"] == "ApiDown":
            continue

        policies.append(
            {
                "name": rule["alert"],
                "query": collapse(inline(rule["expr"], recordings)),
                "duration": rule.get("for", "0s"),
                "severity": labels.get("severity", "warning"),
                "pages": labels.get("page", "false") == "true",
                "slo": labels.get("slo", ""),
                "summary": collapse(annotations.get("summary", rule["alert"])),
                "description": collapse(annotations.get("description", "")),
            }
        )
    return sorted(policies, key=lambda p: p["name"])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    rendered = json.dumps({"policies": render()}, indent=2) + "\n"

    if args.check:
        if not OUTPUT.exists():
            print(f"{OUTPUT.relative_to(ROOT)} is missing; run this without --check")
            return 1
        if OUTPUT.read_text() != rendered:
            print(
                f"{OUTPUT.relative_to(ROOT)} is stale.\n"
                "The alert rules changed without the generated policies being "
                "re-rendered. Run: python3 scripts/render_slo_alerts.py"
            )
            return 1
        print(f"ok   {OUTPUT.relative_to(ROOT)} matches the alert rules")
        return 0

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(rendered)
    policies = json.loads(rendered)["policies"]
    print(f"wrote {OUTPUT.relative_to(ROOT)} with {len(policies)} policies")
    for policy in policies:
        marker = "page " if policy["pages"] else "ticket"
        print(f"  {marker}  {policy['name']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
