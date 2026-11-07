#!/usr/bin/env python3
"""Assert the rendered Kubernetes manifests keep their security posture.

helm lint checks that a chart is well formed. It does not check that every
container still runs as non-root, still has limits, or that a credential has
not crept into a manifest as a literal. This does, so a future edit to the
chart cannot quietly drop one of those.

    python3 scripts/check_manifests.py rendered-dev.yaml rendered-prod.yaml
"""

from __future__ import annotations

import sys
from pathlib import Path

import yaml

REQUIRED_PROBES = ("startupProbe", "readinessProbe", "livenessProbe")


# A Rollout carries the same pod spec as a Deployment. Missing it here
# would mean the hardening checks silently stop applying the moment the
# chart switches to progressive delivery.
POD_OWNERS = ("Deployment", "Rollout")


def pod_spec(doc: dict) -> dict | None:
    if doc["kind"] in POD_OWNERS:
        return doc["spec"]["template"]["spec"]
    if doc["kind"] == "CronJob":
        return doc["spec"]["jobTemplate"]["spec"]["template"]["spec"]
    return None


def check(path: Path) -> list[str]:
    docs = [d for d in yaml.safe_load_all(path.read_text()) if d]
    problems: list[str] = []

    if not docs:
        return [f"{path.name}: rendered nothing"]

    for doc in docs:
        kind = doc["kind"]
        name = doc["metadata"]["name"]

        if kind == "Secret":
            problems.append(f"{name}: a Secret is rendered by the chart")

        spec = pod_spec(doc)
        if spec is None:
            continue

        for container in spec["containers"]:
            sc = container.get("securityContext", {})
            if sc.get("runAsNonRoot") is not True:
                problems.append(f"{name}: runAsNonRoot is not set")
            if sc.get("readOnlyRootFilesystem") is not True:
                problems.append(f"{name}: root filesystem is writable")
            if sc.get("allowPrivilegeEscalation") is not False:
                problems.append(f"{name}: privilege escalation is allowed")
            if sc.get("capabilities", {}).get("drop") != ["ALL"]:
                problems.append(f"{name}: capabilities are not dropped")
            if not container.get("resources", {}).get("limits"):
                problems.append(f"{name}: no resource limits")
            if container["image"].endswith(":latest"):
                problems.append(f"{name}: floating :latest tag")
            for env in container.get("env", []):
                if env["name"] == "DATABASE_URL" and "value" in env:
                    problems.append(f"{name}: DATABASE_URL is a literal value")

        if kind in POD_OWNERS:
            container = spec["containers"][0]
            for probe in REQUIRED_PROBES:
                if probe not in container:
                    problems.append(f"{name}: missing {probe}")

        if kind == "Rollout":
            canary = doc["spec"].get("strategy", {}).get("canary", {})
            if not canary.get("steps"):
                problems.append(
                    f"{name}: a Rollout with no canary steps is just a "
                    "Deployment with extra words"
                )
            if "analysis" not in canary:
                problems.append(
                    f"{name}: canary has no analysis, so nothing can abort it"
                )

    return problems


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2

    failed = False
    for arg in argv[1:]:
        path = Path(arg)
        problems = check(path)
        if problems:
            failed = True
            print(f"FAIL {path.name}")
            for problem in problems:
                print(f"  - {problem}")
        else:
            print(f"ok   {path.name}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
