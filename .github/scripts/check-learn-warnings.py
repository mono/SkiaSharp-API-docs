#!/usr/bin/env python3
"""Compare Learn Build warnings with the pull request's warning baseline."""

import csv
import json
import os
import re
import sys
import urllib.request
from collections import Counter
from urllib.parse import urlparse


ALLOWED_HOSTS = {
    "buildapi.docs.microsoft.com",
    "review.docs.microsoft.com",
}


def validate_url(url, label):
    """Require HTTPS URLs hosted by the Learn Build service."""
    parsed = urlparse(url)
    if parsed.scheme != "https":
        raise ValueError(f"{label} must be HTTPS, got: {parsed.scheme}")
    if parsed.hostname not in ALLOWED_HOSTS:
        raise ValueError(f"{label} host '{parsed.hostname}' not in allowed list: {ALLOWED_HOSTS}")


def extract_build_log_url(report_url):
    """Extract the structured JSON log URL from a Learn Build report."""
    validate_url(report_url, "Build report URL")

    request = urllib.request.Request(report_url)
    with urllib.request.urlopen(request, timeout=30) as response:
        content = response.read().decode("utf-8")

    match = re.search(r'build_log_url="([^"]+)"', content)
    if not match:
        raise ValueError("Could not find build_log_url in build report")

    build_log_url = match.group(1)
    validate_url(build_log_url, "Build log URL")
    return build_log_url


def fetch_build_log(build_log_url):
    """Return warning and error entries from the structured Learn Build log."""
    request = urllib.request.Request(build_log_url)
    with urllib.request.urlopen(request, timeout=30) as response:
        data = json.loads(response.read().decode("utf-8-sig"))

    items = data.get("build_log_error_items")
    if not isinstance(items, list):
        raise ValueError("Build log JSON is missing a build_log_error_items list")

    warnings = []
    errors = []

    for item in items:
        if not isinstance(item, dict):
            raise ValueError("Build log contains a non-object item")

        severity = item.get("message_severity")
        if severity not in (0, 1, 5):
            raise ValueError(f"Unknown Learn Build severity: {severity}")

        entry = "{file}|{code}|{message}".format(
            file=item.get("file", ""),
            code=item.get("code", ""),
            message=item.get("message", ""),
        )
        if severity == 0:
            errors.append(entry)
        elif severity == 1:
            warnings.append(entry)

    return sorted(warnings), sorted(errors)


def load_baseline(path):
    """Load warning counts from known-warnings.csv."""
    if not os.path.exists(path):
        raise ValueError(f"Warning baseline not found: {path}")

    baseline = Counter()
    with open(path, newline="") as baseline_file:
        reader = csv.DictReader(baseline_file)
        required_columns = {"file", "code", "message", "count"}
        actual_columns = set(reader.fieldnames or [])
        if not required_columns.issubset(actual_columns):
            missing = required_columns - actual_columns
            raise ValueError(f"Warning baseline is missing columns: {missing}")

        for row in reader:
            entry = f"{row['file']}|{row['code']}|{row['message']}"
            try:
                baseline[entry] = int(row["count"])
            except ValueError as error:
                raise ValueError(f"Invalid count '{row['count']}' for: {entry}") from error

    return baseline


def compare_warnings(current, baseline):
    """Return warnings added beyond and removed from the baseline."""
    current_counts = Counter(current)

    new_warnings = []
    for entry, count in sorted(current_counts.items()):
        new_warnings.extend([entry] * (count - baseline.get(entry, 0)))

    removed_warnings = []
    for entry, count in sorted(baseline.items()):
        removed_warnings.extend([entry] * (count - current_counts.get(entry, 0)))

    return new_warnings, removed_warnings


def write_report(path, warning_count, baseline_count, errors, new, removed):
    """Write the complete Learn warning comparison as Markdown."""
    if not path:
        return

    lines = [
        "## Learn Build warning report",
        "",
        f"- Build errors: **{len(errors)}**",
        f"- Build warnings: **{warning_count}**",
        f"- Recorded baseline warnings: **{baseline_count}**",
    ]

    sections = [
        ("Build errors", errors),
        ("Unrecorded warnings", new),
        ("Warnings no longer produced", removed),
    ]
    for title, entries in sections:
        if not entries:
            continue
        lines.extend(["", f"### {title}", "", "```text"])
        lines.extend(entries)
        lines.append("```")

    if not errors and not new:
        lines.extend(["", "No unrecorded warnings or build errors were found."])

    with open(path, "w") as report:
        report.write("\n".join(lines))
        report.write("\n")


def main():
    report_url = os.environ.get("BUILD_REPORT_URL")
    if not report_url:
        print("ERROR: BUILD_REPORT_URL environment variable not set")
        sys.exit(1)

    baseline_path = os.path.join(os.environ.get("GITHUB_WORKSPACE", "."), ".github", "known-warnings.csv")
    report_path = os.environ.get("REPORT_PATH")
    baseline = load_baseline(baseline_path)
    baseline_total = sum(baseline.values())

    print("Fetching structured Learn Build log...")
    build_log_url = extract_build_log_url(report_url)
    current_warnings, current_errors = fetch_build_log(build_log_url)

    if current_errors:
        write_report(report_path, len(current_warnings), baseline_total, current_errors, [], [])
        print(f"{len(current_errors)} Learn Build error(s) found:")
        for error in current_errors:
            print(f"  ! {error}")
        sys.exit(1)

    print(
        f"Found {len(current_warnings)} warnings; baseline has {len(baseline)} unique warnings "
        f"({baseline_total} total)"
    )

    new_warnings, removed_warnings = compare_warnings(current_warnings, baseline)

    if removed_warnings:
        print(f"{len(removed_warnings)} warning(s) are no longer produced:")
        for warning in removed_warnings:
            print(f"  - {warning}")

    if new_warnings:
        print(f"{len(new_warnings)} unrecorded warning(s) found:")
        for warning in new_warnings:
            print(f"  + {warning}")

    write_report(report_path, len(current_warnings), baseline_total, [], new_warnings, removed_warnings)

    if new_warnings:
        sys.exit(1)

    print("Learn Build warnings match the recorded baseline")


if __name__ == "__main__":
    main()
