#!/usr/bin/env python3
"""Check Learn Build bot comments on a PR and decide if auto-merge is safe.

This script:
1. Fetches all comments from the PR
2. Finds the latest PoliCheck and Build Report comments from learn-build-service-prod
3. Validates PoliCheck shows "No issues found"
4. Fetches the full build report, extracts the JSON build log URL, and parses warnings
5. Compares warnings against the known-warnings.txt baseline
6. Exits 0 if safe to merge, 1 if not

Environment variables:
  GH_TOKEN       - GitHub token for API access
  PR_NUMBER      - Pull request number
  GITHUB_OUTPUT  - GitHub Actions output file
"""

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


def get_pr_comments(pr_number):
    """Get all comments on a PR, sorted by creation time."""
    raw = gh(
        "pr", "view", str(pr_number),
        "--json", "comments,headRefName,headRefOid",
    )
    return json.loads(raw)


def find_latest_bot_comments(comments, head_sha):
    """Find the latest PoliCheck and Build Report comments for the head commit.

    The Build Report comment contains the commit SHA, so we can match it.
    PoliCheck comments don't contain the SHA, so we take the latest one
    that was posted BEFORE or at the same time as the matching Build Report.
    """
    policheck = None
    build_report = None

    for comment in comments:
        if comment["author"]["login"] != "learn-build-service-prod":
            continue

        body = comment["body"]

        if "PoliCheck Scan Report" in body:
            policheck = comment

        if "Validation status:" in body and head_sha[:7] in body:
            build_report = comment

    return policheck, build_report


def check_policheck(comment):
    """Check if PoliCheck report shows no issues. Returns (ok, message)."""
    body = comment["body"]
    if ":white_check_mark:  No issues found" in body:
        return True, "PoliCheck: No issues found"
    if ":white_check_mark:" in body and "No issues found" in body:
        return True, "PoliCheck: No issues found"
    return False, "PoliCheck: Issues found - manual review required"


def extract_build_report_url(comment):
    """Extract the full build report URL from the Build Report comment."""
    body = comment["body"]
    match = re.search(
        r'\[build report\]\((https://buildapi\.docs\.microsoft\.com/[^)]+)\)',
        body, re.IGNORECASE,
    )
    if match:
        return match.group(1)
    return None


def check_build_status(comment):
    """Check if the build has errors. Returns (has_errors, status_text)."""
    body = comment["body"]
    if ":x:" in body and "errors" in body.lower():
        return True, "Build has errors"
    return False, "No build errors"


def extract_build_log_url(report_url):
    """Fetch the build report HTML and extract the JSON build log URL.

    The build report page has a `build_log_url` attribute on the #Summary element
    that points to a JSON endpoint with structured warning data.
    """
    req = urllib.request.Request(report_url)
    with urllib.request.urlopen(req, timeout=30) as response:
        content = response.read().decode("utf-8")

    match = re.search(r'build_log_url="([^"]+)"', content)
    if match:
        return match.group(1), None
    return None, "Could not find build_log_url in build report HTML"


def fetch_build_log_warnings(build_log_url):
    """Fetch the JSON build log and extract all warnings.

    The JSON has a `build_log_error_items` array with structured entries
    containing file, code, message, and severity fields.
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
        file_path = item.get("file", "")
        code = item.get("code", "")
        message = item.get("message", "")
        entry = f"{file_path}|{code}|{message}"

        if severity == 0:  # Error
            errors.append(entry)
        elif severity == 1:  # Warning
            warnings.append(entry)

    warnings.sort()
    errors.sort()
    return warnings, errors


def load_baseline(path):
    """Load the known-warnings.txt baseline file."""
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return sorted(line.strip() for line in f if line.strip())


def compare_warnings(current, baseline):
    """Compare current warnings against baseline.

    Returns (ok, new_warnings, removed_warnings).
    - ok is True if there are no NEW warnings (removals are fine).
    """
    current_set = set(current)
    baseline_set = set(baseline)

    new_warnings = sorted(current_set - baseline_set)
    removed_warnings = sorted(baseline_set - current_set)

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
        ".github", "known-warnings.txt",
    )

    # Get PR info and comments
    print(f"Checking PR #{pr_number}...")
    pr_data = get_pr_comments(pr_number)
    head_ref = pr_data["headRefName"]
    head_sha = pr_data["headRefOid"]
    comments = pr_data["comments"]

    print(f"  Branch: {head_ref}")
    print(f"  Head SHA: {head_sha[:12]}")
    print(f"  Total comments: {len(comments)}")

    # Only auto-merge the automation branch
    if head_ref != "automation/update-api-docs":
        print(f"  Skipping: not the automation branch (got {head_ref})")
        set_output("should_merge", "false")
        set_output("reason", "Not the automation branch")
        sys.exit(0)

    # Find latest bot comments for the head commit
    policheck, build_report = find_latest_bot_comments(comments, head_sha)

    if not policheck:
        print("  Waiting: no PoliCheck comment found yet")
        set_output("should_merge", "false")
        set_output("reason", "Waiting for PoliCheck comment")
        sys.exit(0)

    if not build_report:
        print("  Waiting: no Build Report comment found for head commit")
        set_output("should_merge", "false")
        set_output("reason", "Waiting for Build Report comment")
        sys.exit(0)

    print("  Found both PoliCheck and Build Report comments")

    # Check PoliCheck
    poli_ok, poli_msg = check_policheck(policheck)
    print(f"  {poli_msg}")
    if not poli_ok:
        set_output("should_merge", "false")
        set_output("reason", poli_msg)
        sys.exit(1)

    # Check for build errors
    has_errors, error_msg = check_build_status(build_report)
    print(f"  {error_msg}")
    if has_errors:
        set_output("should_merge", "false")
        set_output("reason", "Build has errors - manual review required")
        sys.exit(1)

    # Extract and fetch the full build report
    report_url = extract_build_report_url(build_report)
    if not report_url:
        print("  WARNING: Could not find build report URL in comment")
        set_output("should_merge", "false")
        set_output("reason", "Could not find build report URL")
        sys.exit(1)

    print("  Fetching build report to find JSON log URL...")
    build_log_url, log_err = extract_build_log_url(report_url)
    if log_err:
        print(f"  ERROR: {log_err}")
        set_output("should_merge", "false")
        set_output("reason", f"Failed to extract build log URL: {log_err}")
        sys.exit(1)

    print("  Fetching structured build log (JSON)...")
    current_warnings, current_errors = fetch_build_log_warnings(build_log_url)

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
        print("  WARNING: No baseline file found at .github/known-warnings.txt")
        print("  Cannot compare warnings - manual review required")
        set_output("should_merge", "false")
        set_output("reason", "No baseline file found")
        sys.exit(1)

    print(f"  Baseline has {len(baseline)} known warnings")

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
