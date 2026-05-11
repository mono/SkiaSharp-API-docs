#!/usr/bin/env python3
"""Check Learn Build PR statuses and decide if auto-merge is safe.

This script reads GitHub commit statuses (not PR comments) to determine
if a docs PR can be auto-merged. The two Learn Build statuses each have
a targetUrl pointing to a build report, which links to a JSON build log.

Flow:
1. Get PR status checks via gh CLI
2. Verify all checks are green (SUCCESS / COMPLETED+SUCCESS)
3. Find the OpenPublishing.Build targetUrl → build report → JSON build log
4. Extract warnings/errors from the JSON log
5. Compare warnings against the known-warnings.csv baseline
6. Exit 0 if safe to merge, 1 if not

Environment variables:
  GH_TOKEN       - GitHub token for API access
  PR_NUMBER      - Pull request number
  GITHUB_OUTPUT  - GitHub Actions output file
"""

import csv
import json
import os
import re
import subprocess
import sys
import urllib.request


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
        "--json", "headRefName,statusCheckRollup",
    )
    return json.loads(raw)


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


def extract_build_log_url(report_url):
    """Fetch the build report HTML and extract the JSON build log URL.

    The build report page has a `build_log_url` attribute on the #Summary
    element that points to a JSON endpoint with structured data.
    """
    req = urllib.request.Request(report_url)
    with urllib.request.urlopen(req, timeout=30) as response:
        content = response.read().decode("utf-8")

    match = re.search(r'build_log_url="([^"]+)"', content)
    if match:
        return match.group(1)
    return None


def fetch_build_log(build_log_url):
    """Fetch the JSON build log and categorize items by severity.

    Returns (warnings, errors) where each is a sorted list of
    'file|code|message' strings.
    """
    req = urllib.request.Request(build_log_url)
    with urllib.request.urlopen(req, timeout=30) as response:
        raw = response.read().decode("utf-8-sig")
        data = json.loads(raw)

    items = data.get("build_log_error_items", [])
    warnings = []
    errors = []

    for item in items:
        severity = item.get("message_severity", -1)
        entry = "{file}|{code}|{message}".format(
            file=item.get("file", ""),
            code=item.get("code", ""),
            message=item.get("message", ""),
        )
        if severity == 0:
            errors.append(entry)
        elif severity == 1:
            warnings.append(entry)

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
        for row in reader:
            entry = f"{row['file']}|{row['code']}|{row['message']}"
            baseline[entry] = int(row["count"])
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

    baseline_path = os.path.join(
        os.environ.get("GITHUB_WORKSPACE", "."),
        ".github", "known-warnings.csv",
    )

    # Get PR info
    print(f"Checking PR #{pr_number}...")
    pr_data = get_pr_info(pr_number)
    head_ref = pr_data["headRefName"]

    print(f"  Branch: {head_ref}")

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
        names = ", ".join(f"{n} ({s})" for n, s in failures)
        print(f"  ❌ Not all checks are green: {names}")
        set_output("should_merge", "false")
        set_output("reason", f"Checks not green: {names}")
        sys.exit(1)

    print("  All status checks are green")

    # Get the OpenPublishing.Build report URL from the status targetUrl
    build_status = status_map.get("OpenPublishing.Build")
    if not build_status or not build_status["url"]:
        print("  ERROR: No OpenPublishing.Build status with targetUrl found")
        set_output("should_merge", "false")
        set_output("reason", "No OpenPublishing.Build status found")
        sys.exit(1)

    report_url = build_status["url"]
    print(f"  Fetching build report from status targetUrl...")
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
