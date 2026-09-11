#!/usr/bin/env python3
"""Check Learn Build PR statuses and decide if auto-merge is safe.

This script reads GitHub commit statuses (not PR comments) to determine
if a docs PR can be auto-merged. The two Learn Build statuses each have
a targetUrl pointing to a build report, which links to a JSON build log.

Flow:
1. Get PR status checks via gh CLI
2. Verify all required checks are present and green
3. Validate the PR HEAD matches the event SHA (TOCTOU protection)
4. Find the OpenPublishing.Build targetUrl → build report → JSON build log
5. Extract warnings/errors from the JSON log (fail closed on schema changes)
6. Compare warnings against the known-warnings.csv baseline (from main)
7. Exit 0 if safe to merge, 1 if not

Environment variables:
  GH_TOKEN       - GitHub token for API access
  PR_NUMBER      - Pull request number
  VALIDATED_SHA  - The commit SHA from the status event (TOCTOU pin)
  GITHUB_OUTPUT  - GitHub Actions output file
"""

import csv
import json
import os
import re
import subprocess
import sys
import urllib.request
from urllib.parse import urlparse


ALLOWED_HOSTS = {
    "buildapi.docs.microsoft.com",
    "review.docs.microsoft.com",
}

REQUIRED_STATUSES = [
    "OpenPublishing.Build",
    "PoliCheck Scan",
]


def gh(*args):
    """Run a gh CLI command and return stdout."""
    result = subprocess.run(
        ["gh"] + list(args),
        capture_output=True, text=True, check=True,
    )
    return result.stdout.strip()


def get_pr_info(pr_number):
    """Get PR metadata and status checks."""
    raw = gh(
        "pr", "view", str(pr_number),
        "--json", "headRefName,headRefOid,statusCheckRollup",
    )
    return json.loads(raw)


def validate_url(url, label="URL"):
    """Validate that a URL is HTTPS and on an allowed host. Fail closed."""
    parsed = urlparse(url)
    if parsed.scheme != "https":
        raise ValueError(f"{label} must be HTTPS, got: {parsed.scheme}")
    if parsed.hostname not in ALLOWED_HOSTS:
        raise ValueError(
            f"{label} host '{parsed.hostname}' not in allowed list: {ALLOWED_HOSTS}"
        )


def check_statuses(checks):
    """Verify all GitHub commit statuses and check runs are green.

    Returns (all_green, failures, status_map).
    - failures is a list of (name, state) tuples for non-green checks.
    - status_map is a dict of name -> {state, url} for all checks.
    """
    failures = []
    status_map = {}

    for check in checks:
        name = check.get("context") or check.get("name") or "unknown"
        state = check.get("state", "")
        status = check.get("status", "")
        conclusion = check.get("conclusion", "")
        url = check.get("targetUrl") or check.get("detailsUrl") or ""

        is_green = (
            state == "SUCCESS"
            or (status == "COMPLETED" and conclusion == "SUCCESS")
        )
        display_state = state or conclusion or status
        status_map[name] = {"state": display_state, "url": url}

        if not is_green:
            if state == "PENDING" or status in ("IN_PROGRESS", "QUEUED"):
                failures.append((name, "PENDING"))
            else:
                failures.append((name, display_state))

    return len(failures) == 0, failures, status_map


def check_required_statuses(status_map):
    """Verify all required statuses are present and green. Fail closed."""
    missing = []
    not_green = []
    for name in REQUIRED_STATUSES:
        if name not in status_map:
            missing.append(name)
        elif status_map[name]["state"] != "SUCCESS":
            not_green.append((name, status_map[name]["state"]))
    return missing, not_green


def extract_build_log_url(report_url):
    """Fetch the build report HTML and extract the JSON build log URL.

    The build report page has a `build_log_url` attribute on the #Summary
    element that points to a JSON endpoint with structured data.
    """
    validate_url(report_url, "Build report URL")

    req = urllib.request.Request(report_url)
    with urllib.request.urlopen(req, timeout=30) as response:
        content = response.read().decode("utf-8")

    match = re.search(r'build_log_url="([^"]+)"', content)
    if not match:
        return None

    log_url = match.group(1)
    validate_url(log_url, "Build log URL")
    return log_url


def fetch_build_log(build_log_url):
    """Fetch the JSON build log and categorize items by severity.

    Fails closed if the expected JSON structure is missing or malformed.
    Returns (warnings, errors) where each is a sorted list of
    'file|code|message' strings.
    """
    validate_url(build_log_url, "Build log URL")

    req = urllib.request.Request(build_log_url)
    with urllib.request.urlopen(req, timeout=30) as response:
        raw = response.read().decode("utf-8-sig")
        data = json.loads(raw)

    if "build_log_error_items" not in data:
        raise ValueError(
            "Build log JSON missing 'build_log_error_items' key — "
            "schema may have changed. Refusing to proceed."
        )

    items = data["build_log_error_items"]
    if not isinstance(items, list):
        raise ValueError(
            f"'build_log_error_items' is {type(items).__name__}, expected list. "
            "Refusing to proceed."
        )

    warnings = []
    errors = []

    for item in items:
        if not isinstance(item, dict):
            raise ValueError(
                f"Build log item is {type(item).__name__}, expected dict. "
                "Refusing to proceed."
            )
        severity = item.get("message_severity")
        if severity is None:
            raise ValueError(
                "Build log item missing 'message_severity'. Refusing to proceed."
            )
        entry = "{file}|{code}|{message}".format(
            file=item.get("file", ""),
            code=item.get("code", ""),
            message=item.get("message", ""),
        )
        if severity == 0:
            errors.append(entry)
        elif severity == 1:
            warnings.append(entry)
        # Severity 5 = Suggestion — safe to ignore.
        # Any other unknown severity is also ignored since we fail closed
        # on the warning comparison (unknown items don't reduce the count).

    warnings.sort()
    errors.sort()
    return warnings, errors


def load_baseline(path):
    """Load the known-warnings.csv baseline file.

    Returns a Counter mapping 'file|code|message' -> count.
    """
    from collections import Counter

    if not os.path.exists(path):
        return None
    baseline = Counter()
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        required_cols = {"file", "code", "message", "count"}
        if not required_cols.issubset(set(reader.fieldnames or [])):
            raise ValueError(
                f"Baseline CSV missing columns: {required_cols - set(reader.fieldnames or [])}. "
                "Refusing to proceed."
            )
        for row in reader:
            entry = f"{row['file']}|{row['code']}|{row['message']}"
            try:
                baseline[entry] = int(row["count"])
            except ValueError:
                raise ValueError(
                    f"Invalid count '{row['count']}' in baseline for: {entry}"
                )
    return baseline


def compare_warnings(current, baseline):
    """Compare current warnings against baseline using multiset comparison.

    current is a sorted list of 'file|code|message' strings (may have dupes).
    baseline is a Counter mapping 'file|code|message' -> expected count.

    Returns (ok, new_warnings, removed_warnings).
    - ok is True if there are no NEW warnings (removals are fine).
    """
    from collections import Counter

    current_counts = Counter(current)

    new_warnings = []
    for entry, count in sorted(current_counts.items()):
        extra = count - baseline.get(entry, 0)
        for _ in range(extra):
            new_warnings.append(entry)

    removed_warnings = []
    for entry, count in sorted(baseline.items()):
        missing = count - current_counts.get(entry, 0)
        for _ in range(missing):
            removed_warnings.append(entry)

    return len(new_warnings) == 0, new_warnings, removed_warnings


def set_output(name, value):
    """Set a GitHub Actions output variable."""
    output_file = os.environ.get("GITHUB_OUTPUT")
    if output_file:
        with open(output_file, "a") as f:
            f.write(f"{name}={value}\n")


def main():
    pr_number = os.environ.get("PR_NUMBER")
    if not pr_number:
        print("ERROR: PR_NUMBER environment variable not set")
        sys.exit(1)

    validated_sha = os.environ.get("VALIDATED_SHA", "")

    baseline_path = os.path.join(
        os.environ.get("GITHUB_WORKSPACE", "."),
        ".github", "known-warnings.csv",
    )

    # Get PR info
    print(f"Checking PR #{pr_number}...")
    pr_data = get_pr_info(pr_number)
    head_ref = pr_data["headRefName"]
    head_sha = pr_data["headRefOid"]

    print(f"  Branch: {head_ref}")
    print(f"  PR HEAD: {head_sha[:12]}")

    # TOCTOU protection: verify the PR HEAD hasn't changed since the status event
    if validated_sha and head_sha != validated_sha:
        print(f"  ❌ PR HEAD ({head_sha[:12]}) != event SHA ({validated_sha[:12]})")
        print("  PR was updated after status event fired. Skipping.")
        set_output("should_merge", "false")
        set_output("reason", "PR HEAD changed since status event")
        sys.exit(1)

    # Check all GitHub statuses are green
    checks = pr_data.get("statusCheckRollup", [])
    if not checks:
        print("  Waiting: no status checks found yet")
        set_output("should_merge", "false")
        set_output("reason", "No status checks found")
        sys.exit(0)

    all_green, failures, status_map = check_statuses(checks)
    print(f"  Status checks ({len(checks)}):")
    for name, info in sorted(status_map.items()):
        print(f"    {name}: {info['state']}")

    if not all_green:
        # Distinguish "still pending" from "actually failed"
        only_pending = all(s == "PENDING" for _, s in failures)
        if only_pending:
            names = ", ".join(n for n, _ in failures)
            print(f"  Waiting: checks still pending: {names}")
            set_output("should_merge", "false")
            set_output("reason", f"Waiting for: {names}")
            sys.exit(0)
        else:
            names = ", ".join(f"{n} ({s})" for n, s in failures)
            print(f"  ❌ Not all checks are green: {names}")
            set_output("should_merge", "false")
            set_output("reason", f"Checks not green: {names}")
            sys.exit(1)

    # Verify all required statuses are present
    missing, not_green = check_required_statuses(status_map)
    if missing:
        print(f"  Waiting: required status(es) not yet reported: {', '.join(missing)}")
        set_output("should_merge", "false")
        set_output("reason", f"Waiting for: {', '.join(missing)}")
        sys.exit(0)
    if not_green:
        names = ", ".join(f"{n} ({s})" for n, s in not_green)
        print(f"  ❌ Required status(es) not green: {names}")
        set_output("should_merge", "false")
        set_output("reason", f"Required checks failed: {names}")
        sys.exit(1)

    print("  All required status checks are green")

    # Get the OpenPublishing.Build report URL from the status targetUrl
    build_status = status_map.get("OpenPublishing.Build")
    if not build_status or not build_status["url"]:
        print("  ERROR: No OpenPublishing.Build status with targetUrl found")
        set_output("should_merge", "false")
        set_output("reason", "No OpenPublishing.Build status found")
        sys.exit(1)

    report_url = build_status["url"]
    print("  Fetching build report from status targetUrl...")
    build_log_url = extract_build_log_url(report_url)
    if not build_log_url:
        print("  ERROR: Could not find build_log_url in build report")
        set_output("should_merge", "false")
        set_output("reason", "Could not find build_log_url in report")
        sys.exit(1)

    print("  Fetching structured build log (JSON)...")
    current_warnings, current_errors = fetch_build_log(build_log_url)

    if current_errors:
        print(f"  ❌ {len(current_errors)} build error(s) found:")
        for e in current_errors:
            print(f"    ! {e}")
        set_output("should_merge", "false")
        set_output("reason", f"{len(current_errors)} build error(s) found")
        sys.exit(1)

    print(f"  Found {len(current_warnings)} warnings in build log")

    # Load and compare baseline
    baseline = load_baseline(baseline_path)
    if baseline is None:
        print("  WARNING: No baseline file found at .github/known-warnings.csv")
        print("  Cannot compare warnings - manual review required")
        set_output("should_merge", "false")
        set_output("reason", "No baseline file found")
        sys.exit(1)

    baseline_total = sum(baseline.values())
    print(f"  Baseline has {len(baseline)} unique warnings ({baseline_total} total)")

    ok, new_warnings, removed_warnings = compare_warnings(
        current_warnings, baseline,
    )

    if removed_warnings:
        print(f"  {len(removed_warnings)} warning(s) were resolved (good!):")
        for w in removed_warnings[:5]:
            print(f"    - {w}")
        if len(removed_warnings) > 5:
            print(f"    ... and {len(removed_warnings) - 5} more")

    if new_warnings:
        print(f"  {len(new_warnings)} NEW warning(s) found:")
        for w in new_warnings:
            print(f"    + {w}")

        summary = f"{len(new_warnings)} new warning(s) found"
        set_output("should_merge", "false")
        set_output("reason", summary)
        set_output("new_warnings", json.dumps(new_warnings))
        sys.exit(1)

    print("  ✅ All checks passed - safe to merge!")
    set_output("should_merge", "true")
    set_output("reason", "All checks passed")
    sys.exit(0)


if __name__ == "__main__":
    main()
