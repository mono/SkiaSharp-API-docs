#!/usr/bin/env python3
"""Require all pull request checks to be green before automerge."""

import json
import os
import subprocess
import sys


DEFAULT_REQUIRED_STATUSES = [
    "OpenPublishing.Build",
    "PoliCheck Scan",
    "Learn warnings",
]


def gh(*args):
    """Run a gh CLI command and return stdout."""
    result = subprocess.run(
        ["gh", *args],
        capture_output=True,
        text=True,
        check=True,
    )
    return result.stdout.strip()


def set_output(name, value):
    """Set a GitHub Actions output value."""
    output_file = os.environ.get("GITHUB_OUTPUT")
    if output_file:
        with open(output_file, "a") as file:
            file.write(f"{name}={value}\n")


def parse_list(name, default=""):
    """Parse a comma-separated environment variable."""
    return [
        value.strip()
        for value in os.environ.get(name, default).split(",")
        if value.strip()
    ]


def collect_statuses(checks, ignored_statuses):
    """Collect check states and return non-green checks."""
    failures = []
    status_map = {}

    for check in checks:
        name = check.get("context") or check.get("name") or "unknown"
        if name in ignored_statuses:
            continue

        state = check.get("state", "")
        status = check.get("status", "")
        conclusion = check.get("conclusion", "")
        display_state = state or conclusion or status
        is_green = (
            state == "SUCCESS"
            or (status == "COMPLETED" and conclusion == "SUCCESS")
        )

        status_map[name] = display_state
        if not is_green:
            pending = state == "PENDING" or status in ("IN_PROGRESS", "QUEUED")
            failures.append((name, "PENDING" if pending else display_state))

    return failures, status_map


def main():
    pr_number = os.environ.get("PR_NUMBER")
    if not pr_number:
        print("ERROR: PR_NUMBER environment variable not set")
        sys.exit(1)

    validated_sha = os.environ.get("VALIDATED_SHA", "")
    required_statuses = parse_list(
        "REQUIRED_STATUSES",
        ",".join(DEFAULT_REQUIRED_STATUSES),
    )
    ignored_statuses = set(parse_list("IGNORED_STATUSES"))

    raw = gh(
        "pr",
        "view",
        pr_number,
        "--json",
        "headRefName,headRefOid,statusCheckRollup",
    )
    pr_data = json.loads(raw)
    head_sha = pr_data["headRefOid"]

    print(f"Checking PR #{pr_number} ({pr_data['headRefName']})")
    print(f"  PR HEAD: {head_sha[:12]}")

    if validated_sha and head_sha != validated_sha:
        print(
            f"  PR HEAD ({head_sha[:12]}) does not match "
            f"event SHA ({validated_sha[:12]})"
        )
        set_output("should_merge", "false")
        set_output("reason", "PR HEAD changed since event")
        sys.exit(1)

    checks = pr_data.get("statusCheckRollup", [])
    if not checks:
        print("  Waiting: no status checks found")
        set_output("should_merge", "false")
        set_output("reason", "No status checks found")
        return

    failures, status_map = collect_statuses(checks, ignored_statuses)
    for name, state in sorted(status_map.items()):
        print(f"  {name}: {state}")

    if failures:
        only_pending = all(state == "PENDING" for _, state in failures)
        if only_pending:
            names = ", ".join(name for name, _ in failures)
            print(f"  Waiting for: {names}")
            set_output("should_merge", "false")
            set_output("reason", f"Waiting for: {names}")
            return

        names = ", ".join(f"{name} ({state})" for name, state in failures)
        print(f"  Checks not green: {names}")
        set_output("should_merge", "false")
        set_output("reason", f"Checks not green: {names}")
        sys.exit(1)

    missing = [name for name in required_statuses if name not in status_map]
    if missing:
        names = ", ".join(missing)
        print(f"  Waiting for required checks: {names}")
        set_output("should_merge", "false")
        set_output("reason", f"Waiting for: {names}")
        return

    print("All PR checks passed")
    set_output("should_merge", "true")
    set_output("reason", "All checks passed")


if __name__ == "__main__":
    main()
