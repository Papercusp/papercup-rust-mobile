#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Keep the store review packets reviewer-sized. Build, license and
# source-provenance evidence goes to android/SOURCE-EVIDENCE.md; it once grew
# store/APP-STORE-REVIEW.md to ~2,700 lines of depot_tools/WebRTC preparation
# notes. Rejecting controls run against copies so a broken checker cannot pass.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

check() {
    python3 - "$1" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
packets = {
    "store/APP-STORE-REVIEW.md": "iPhone",
    "store/PLAY-STORE-REVIEW.md": "Android",
}
evidence = root / "android/SOURCE-EVIDENCE.md"
MAX_LINES = 250
EVIDENCE_HEADING = re.compile(
    r"^#{1,6} .*(source preparation|depot_tools|Retained |Pinned |"
    r"source evidence|provenance|dependency source)", re.I)
ANDROID_HEADING = re.compile(r"^#{1,6} .*(Android|Google Play)", re.I)

errors = []
if not evidence.is_file():
    errors.append("missing android/SOURCE-EVIDENCE.md (the evidence append target)")
for relative, platform in packets.items():
    path = root / relative
    if not path.is_file():
        errors.append(f"missing {relative}")
        continue
    lines = path.read_text(encoding="utf-8").splitlines()
    if len(lines) > MAX_LINES:
        errors.append(f"{relative} has {len(lines)} lines (> {MAX_LINES}); "
                      "move evidence to android/SOURCE-EVIDENCE.md")
    for number, line in enumerate(lines, 1):
        if EVIDENCE_HEADING.search(line):
            errors.append(f"{relative}:{number}: evidence heading in a review packet: {line}")
        if platform == "iPhone" and ANDROID_HEADING.search(line):
            errors.append(f"{relative}:{number}: Android section belongs in "
                          f"store/PLAY-STORE-REVIEW.md: {line}")
if errors:
    print("\n".join(f"ERROR: {e}" for e in errors), file=sys.stderr)
    sys.exit(1)
PY
}

expect_reject() {
    local label="$1" tmp="$2"
    if check "$tmp" 2>/dev/null; then
        echo "FAIL: rejecting control accepted: $label" >&2
        exit 1
    fi
}

check "$ROOT"

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
fixture() {
    rm -rf -- "${tmp:?}/root"
    mkdir -p "$tmp/root/store" "$tmp/root/android"
    cp "$ROOT/store/APP-STORE-REVIEW.md" "$ROOT/store/PLAY-STORE-REVIEW.md" "$tmp/root/store/"
    cp "$ROOT/android/SOURCE-EVIDENCE.md" "$tmp/root/android/"
}

fixture
check "$tmp/root"

fixture
printf '\n## Pinned depot_tools gsutil source preparation\n' >> "$tmp/root/store/PLAY-STORE-REVIEW.md"
expect_reject "evidence heading appended to the Play packet" "$tmp/root"

fixture
printf '\n## Android / Google Play reviewer preparation\n' >> "$tmp/root/store/APP-STORE-REVIEW.md"
expect_reject "Android section in the Apple packet" "$tmp/root"

fixture
for _ in $(seq 300); do echo 'filler line'; done >> "$tmp/root/store/APP-STORE-REVIEW.md"
expect_reject "oversized review packet" "$tmp/root"

fixture
rm "$tmp/root/android/SOURCE-EVIDENCE.md"
expect_reject "missing evidence append target" "$tmp/root"

echo "store packet scope: PASS (4 rejecting controls)"
