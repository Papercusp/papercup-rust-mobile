#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Cloud-workspace store copy stays pending until the device relay ships.
#
# iphone-public-release-2026-08-11#D-016: all cloud copy is marked pending until
# the device-http relay (P-015) is verified live, and is never presented as
# shipped before then. Each file below keeps its cloud wording in a
# "## Pending: cloud workspace ..." section; above that heading, every
# paragraph, list item or table row that mentions a cloud workspace, the relay,
# end-to-end encryption or Papercusp hosting must also say it is pending.
#
# Retire this test and its Makefile target in the same change that moves the
# pending copy into the submittable sections, after P-015 is verified live on
# the platform being submitted. Rejecting controls run against copies so a
# broken checker cannot pass.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FILES=(
    store/LISTING.md
    store/PRIVACY-POLICY.md
    store/APP-STORE-PRIVACY.md
    store/APP-STORE-REVIEW.md
)

check() {
    python3 - "$1" "${FILES[@]}" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
PENDING_HEADING = re.compile(r"^## Pending: cloud workspace", re.I)
MARKER = "Pending — not yet available"
CLOUD = re.compile(r"cloud workspace|cloud account|\brelay\b|end-to-end|"
                   r"Papercusp-hosted|\bBYOC\b", re.I)
ALLOW = re.compile(r"pending|not available yet", re.I)
UNIT_START = re.compile(r"^(\||[-*] |\d+\. |#)")

def units(lines, first):
    """Paragraphs, split further so each list item and table row stands alone."""
    unit, start = [], first
    for number, line in enumerate(lines, first):
        if not line.strip():
            if unit:
                yield start, " ".join(unit)
            unit = []
            continue
        if unit and UNIT_START.match(line):
            yield start, " ".join(unit)
            unit = []
        if not unit:
            start = number
        unit.append(line.strip())
    if unit:
        yield start, " ".join(unit)

errors = []
for relative in sys.argv[2:]:
    path = root / relative
    if not path.is_file():
        errors.append(f"missing {relative}")
        continue
    lines = path.read_text(encoding="utf-8").splitlines()
    headings = [i for i, line in enumerate(lines) if PENDING_HEADING.match(line)]
    if len(headings) != 1:
        errors.append(f"{relative}: expected one '## Pending: cloud workspace' "
                      f"section, found {len(headings)}")
        continue
    cut = headings[0]
    section_end = next((i for i in range(cut + 1, len(lines))
                        if lines[i].startswith("## ")), len(lines))
    if MARKER not in "\n".join(lines[cut:section_end]):
        errors.append(f"{relative}: pending section lacks the '{MARKER}' marker")
    for number, text in units(lines[:cut], 1):
        if CLOUD.search(text) and not ALLOW.search(text):
            errors.append(f"{relative}:{number}: cloud-workspace wording outside "
                          f"the pending section: {text[:120]}")
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
    mkdir -p "$tmp/root/store"
    for f in "${FILES[@]}"; do cp "$ROOT/$f" "$tmp/root/store/"; done
}
# Insert a line just before the pending heading of one fixture file.
insert_before_pending() {
    python3 - "$1" "$2" <<'PY'
import sys
from pathlib import Path
path, text = Path(sys.argv[1]), sys.argv[2]
lines = path.read_text(encoding="utf-8").splitlines()
cut = next(i for i, l in enumerate(lines) if l.startswith("## Pending: cloud workspace"))
lines[cut:cut] = [text, ""]
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
}

fixture
check "$tmp/root"

fixture
insert_before_pending "$tmp/root/store/LISTING.md" \
    "Cloud workspaces connect through Papercusp's relay."
expect_reject "shipped-sounding cloud paragraph in the listing body" "$tmp/root"

fixture
python3 - "$tmp/root/store/APP-STORE-PRIVACY.md" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
row = "| Identifiers → Device ID |"
assert row in text, "calibration: Device ID row not found"
text = text.replace(row, "| Identifiers → User ID | Yes | Yes | No | App Functionality | "
                         "relay routing for cloud workspaces |\n" + row, 1)
path.write_text(text, encoding="utf-8")
PY
expect_reject "cloud row added to a table that contains other rows" "$tmp/root"

fixture
sed -i 's/^## Pending: cloud workspace connections$/## Cloud workspace connections/' \
    "$tmp/root/store/PRIVACY-POLICY.md"
expect_reject "pending heading renamed to a shipped heading" "$tmp/root"

fixture
sed -i 's/Pending — not yet available\./Now available./' "$tmp/root/store/APP-STORE-REVIEW.md"
expect_reject "pending marker removed from the review packet" "$tmp/root"

echo "store cloud pending: PASS (4 rejecting controls)"
