#!/usr/bin/env python3
"""Fail-closed final ship gate for a pull request's Full CI run."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from typing import Any


PLATFORMS = (
    "linux-x86_64",
    "linux-aarch64",
    "macos-x86_64",
    "macos-aarch64",
)
WORKFLOW = "Full CI"


def _objects(payload: Any, label: str) -> list[dict[str, Any]]:
    if not isinstance(payload, list) or any(not isinstance(item, dict) for item in payload):
        raise ValueError(f"{label} must be a JSON array of objects")
    return payload


def select_exact_run(runs: Any, sha: str) -> dict[str, Any]:
    """Select the newest Full CI run for sha, requiring it to have completed successfully."""
    all_runs = _objects(runs, "runs")
    matching = [run for run in all_runs if run.get("headSha") == sha]
    if not matching:
        raise ValueError(f"no Full CI run found for {sha}")
    if any(not isinstance(run.get("createdAt"), str) for run in matching):
        raise ValueError("Full CI run has invalid createdAt")
    matching.sort(key=lambda run: (run["createdAt"], run.get("databaseId", 0)), reverse=True)
    run = matching[0]
    if run.get("status") != "completed" or run.get("conclusion") != "success":
        raise ValueError(
            f"latest Full CI run for {sha} is not successful: "
            f"status={run.get('status')!r} conclusion={run.get('conclusion')!r}"
        )
    if not isinstance(run.get("databaseId"), int):
        raise ValueError("successful Full CI run has no numeric databaseId")
    return run


def verify_platform_jobs(jobs: Any) -> None:
    selected: dict[str, dict[str, Any]] = {}
    for job in _objects(jobs, "jobs"):
        name = job.get("name")
        if not isinstance(name, str) or not name.startswith("Full suite ("):
            continue
        if name in selected:
            raise ValueError(f"duplicate Full CI aggregate job: {name}")
        selected[name] = job
    expected = {f"Full suite ({platform})" for platform in PLATFORMS}
    missing = sorted(expected - selected.keys())
    if missing:
        raise ValueError("missing Full CI aggregate jobs: " + ", ".join(missing))
    failed = sorted(
        name for name in expected
        if selected[name].get("status") != "completed"
        or selected[name].get("conclusion") != "success"
    )
    if failed:
        raise ValueError("Full CI aggregate jobs did not succeed: " + ", ".join(failed))


def gh_json(repo: str, *args: str) -> Any:
    result = subprocess.run(
        ["gh", *args],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or f"exit {result.returncode}"
        raise RuntimeError(f"gh {' '.join(args)} failed: {detail}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"gh {' '.join(args)} returned invalid JSON") from error


def git_head() -> str:
    result = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError("could not determine current HEAD")
    return result.stdout.strip()


def run(pr: str, repo: str) -> str:
    sha = git_head()
    pr_data = gh_json(repo, "pr", "view", pr, "--repo", repo, "--json", "headRefOid")
    if not isinstance(pr_data, dict) or pr_data.get("headRefOid") != sha:
        raise ValueError("current HEAD does not match the PR head")
    runs = gh_json(
        repo,
        "run",
        "list",
        "--repo",
        repo,
        "--workflow",
        WORKFLOW,
        "--limit",
        "100",
        "--json",
        "databaseId,headSha,status,conclusion,createdAt",
    )
    selected = select_exact_run(runs, sha)
    jobs = gh_json(repo, "run", "view", str(selected["databaseId"]), "--repo", repo, "--json", "jobs")
    if not isinstance(jobs, dict):
        raise ValueError("Full CI job response is not an object")
    verify_platform_jobs(jobs.get("jobs"))
    return f"SHIP {sha}"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pr", required=True, help="pull request number")
    parser.add_argument("--repo", required=True, help="explicit owner/repository")
    args = parser.parse_args(argv)
    try:
        print(run(args.pr, args.repo))
    except (RuntimeError, ValueError) as error:
        print(f"HOLD: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
