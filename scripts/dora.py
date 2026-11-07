#!/usr/bin/env python3
"""Compute the DORA delivery metrics for this repository.

Deployment frequency and lead time for changes are derived from the git
history and, when a token is available, the GitHub Actions run history.

Change failure rate and time to restore are reported as unavailable rather
than estimated. Both need an incident record to join deploys against, which
a real deployment has and this assignment does not. A number invented from
nothing would be worse than an honest gap, because it would look measured.

    python3 scripts/dora.py --days 30
    GITHUB_TOKEN=... python3 scripts/dora.py --days 30 --repo owner/name
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import UTC, datetime, timedelta

API = "https://api.github.com"


def git(*args: str) -> str:
    return subprocess.run(
        ["git", *args], capture_output=True, text=True, check=True
    ).stdout.strip()


def fetch_runs(
    repo: str, workflow: str, since: datetime, token: str | None
) -> list[dict]:
    """Successful runs of one workflow. Empty list when unavailable."""
    url = (
        f"{API}/repos/{repo}/actions/workflows/{workflow}/runs"
        f"?status=success&per_page=100&created=>={since.date().isoformat()}"
    )
    request = urllib.request.Request(
        url, headers={"accept": "application/vnd.github+json"}
    )
    if token:
        request.add_header("authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.load(response).get("workflow_runs", [])
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
        return []


def deployment_frequency(runs: list[dict], days: int) -> tuple[float, str]:
    per_day = len(runs) / days if days else 0.0
    # The DORA bands, so the number means something without a lookup.
    if per_day >= 1:
        band = "elite (on demand)"
    elif per_day >= 1 / 7:
        band = "high (weekly to monthly)"
    elif per_day >= 1 / 30:
        band = "medium (monthly)"
    else:
        band = "low (less than monthly)"
    return per_day, band


def lead_times(runs: list[dict]) -> list[float]:
    """Hours from a commit being authored to the deploy that shipped it."""
    hours = []
    for run in runs:
        sha = run.get("head_sha")
        finished = run.get("updated_at")
        if not sha or not finished:
            continue
        try:
            authored = git("show", "-s", "--format=%aI", sha)
        except subprocess.CalledProcessError:
            continue  # commit not in this clone, e.g. a shallow checkout
        try:
            start = datetime.fromisoformat(authored)
            end = datetime.fromisoformat(finished.replace("Z", "+00:00"))
        except ValueError:
            continue
        delta = (end - start).total_seconds() / 3600
        if delta >= 0:
            hours.append(delta)
    return hours


def local_commit_cadence(days: int) -> tuple[int, int]:
    """Fallback when the GitHub API is unavailable: commits and days active."""
    since = (datetime.now(UTC) - timedelta(days=days)).date().isoformat()
    log = git("log", f"--since={since}", "--format=%aI")
    if not log:
        return 0, 0
    dates = {line[:10] for line in log.splitlines()}
    return len(log.splitlines()), len(dates)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--days", type=int, default=30)
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY"))
    parser.add_argument("--workflow", default="deploy.yml")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    since = datetime.now(UTC) - timedelta(days=args.days)
    token = os.environ.get("GITHUB_TOKEN")

    repo = args.repo
    if not repo:
        try:
            remote = git("remote", "get-url", "origin")
            repo = remote.split(":")[-1].removesuffix(".git").split("/")[-2:]
            repo = "/".join(repo)
        except (subprocess.CalledProcessError, IndexError):
            repo = None

    runs = fetch_runs(repo, args.workflow, since, token) if repo else []

    result: dict[str, object] = {"window_days": args.days, "repository": repo}

    if runs:
        per_day, band = deployment_frequency(runs, args.days)
        result["deployment_frequency_per_day"] = round(per_day, 3)
        result["deployment_frequency_band"] = band
        hours = lead_times(runs)
        if hours:
            result["lead_time_hours_median"] = round(statistics.median(hours), 2)
            result["lead_time_hours_p90"] = round(
                sorted(hours)[min(len(hours) - 1, int(len(hours) * 0.9))], 2
            )
        else:
            result["lead_time_hours_median"] = "no commits resolvable in this clone"
    else:
        commits, active_days = local_commit_cadence(args.days)
        result["deployment_frequency_per_day"] = "unavailable"
        result["deployment_frequency_note"] = (
            "No successful deploy runs found. Needs GITHUB_TOKEN and a "
            "repository that has deployed at least once."
        )
        result["commits_in_window"] = commits
        result["days_with_commits"] = active_days

    # Stated, not estimated.
    result["change_failure_rate"] = "unavailable"
    result["time_to_restore_hours"] = "unavailable"
    result["unavailable_because"] = (
        "Both need deploys joined against incident records. There is no "
        "incident source in this repository, and a number derived from "
        "nothing would look measured without being measured."
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return 0

    print(f"DORA metrics over the last {args.days} days")
    print(f"repository: {repo or 'unknown'}")
    print("-" * 60)
    for key, value in result.items():
        if key in ("window_days", "repository", "unavailable_because"):
            continue
        print(f"  {key:<34} {value}")
    print("-" * 60)
    print(result["unavailable_because"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
