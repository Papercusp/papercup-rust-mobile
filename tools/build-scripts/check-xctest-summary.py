#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Admit an XCTest bundle only on real execution evidence.

Reads the JSON written by `xcrun xcresulttool get test-results summary` and
requires nonzero passing tests with zero failures and zero skips. An exit code
of 0 from xcodebuild alone is not evidence: an empty or fully skipped bundle
also exits 0.

Shared by tools/run-ios-template-tests.sh and tools/run-ios-tests.sh (the CI
'Test iOS app' step), so both runners apply one definition of a passing run.

Usage: check-xctest-summary.py <summary.json> <bundle-name>

Exit codes:
  0  admitted: tests executed, all passed, none skipped
  1  rejected: tests executed, but some failed or were skipped
  2  usage error
  3  nothing executed: the counts are zero, missing or unreadable. Only this
     code may be retried, because the Xcode destination-resolver race fails
     before any test runs.
"""

import json
import sys
from pathlib import Path

COUNT_KEYS = ('passedTests', 'failedTests', 'skippedTests')
ADMITTED, REJECTED, USAGE, NOTHING_EXECUTED = 0, 1, 2, 3


def classify(result):
    """Return (exit code, counts) for one decoded summary document."""
    source = result if isinstance(result, dict) else {}
    counts = {key: source.get(key) for key in COUNT_KEYS}
    valid = all(type(value) is int and value >= 0 for value in counts.values())
    if not valid or sum(counts.values()) == 0:
        return NOTHING_EXECUTED, counts
    if counts['passedTests'] > 0 and counts['failedTests'] == 0 and counts['skippedTests'] == 0:
        return ADMITTED, counts
    return REJECTED, counts


def main(argv):
    if len(argv) != 3:
        print('Usage: check-xctest-summary.py <summary.json> <bundle-name>', file=sys.stderr)
        return USAGE
    summary_path, bundle = argv[1], argv[2]
    try:
        result = json.loads(Path(summary_path).read_text())
    except (OSError, ValueError) as error:
        print(
            f'ERROR: {bundle} requires nonzero passing tests, zero failures and zero skips: '
            f'unreadable summary {summary_path} ({error})',
            file=sys.stderr,
        )
        return NOTHING_EXECUTED
    code, counts = classify(result)
    if code == ADMITTED:
        print(f"Executed {counts['passedTests']} passing tests with zero failures/skips in {bundle}")
    else:
        print(
            f'ERROR: {bundle} requires nonzero passing tests, zero failures and zero skips: {counts}',
            file=sys.stderr,
        )
    return code


if __name__ == '__main__':
    sys.exit(main(sys.argv))
