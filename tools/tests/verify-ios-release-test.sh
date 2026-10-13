#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFY="$REPO_ROOT/tools/build-scripts/verify-ios-release.sh"

"$VERIFY"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

files=(
    tools/ios-ci.py
    docs/BUILD.md
    docs/TESTFLIGHT-DEVICE-CHECKLIST.md
    ios/Papercup/Info.plist
    ios/Papercup/Papercup.entitlements
    ios/Papercup/Resources/PrivacyInfo.xcprivacy
    ios/Papercup/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json
    ios/Papercup/Sources/Papercup/AppLinks.swift
    ios/Papercup/Sources/Papercup/PapercupApp.swift
    ios/ExportOptions.plist
    ios/project.yml
    store/LISTING.md
    store/PRIVACY-POLICY.md
    store/APP-STORE-PRIVACY.md
    store/APP-STORE-REVIEW.md
)

copy_fixture() {
    rm -rf "$TMP_ROOT/fixture"
    for relative in "${files[@]}"; do
        mkdir -p "$TMP_ROOT/fixture/$(dirname "$relative")"
        cp "$REPO_ROOT/$relative" "$TMP_ROOT/fixture/$relative"
    done
    for icon in "$REPO_ROOT"/ios/Papercup/Resources/Assets.xcassets/AppIcon.appiconset/*.png; do
        relative="${icon#"$REPO_ROOT"/}"
        mkdir -p "$TMP_ROOT/fixture/$(dirname "$relative")"
        cp "$icon" "$TMP_ROOT/fixture/$relative"
    done
}

expect_failure() {
    local expected="$1"
    set +e
    output="$(PAPERCUP_IOS_RELEASE_ROOT="$TMP_ROOT/fixture" "$VERIFY" 2>&1)"
    rc=$?
    set -e
    if [ "$rc" -eq 0 ] || ! grep -q "$expected" <<<"$output"; then
        echo "ERROR: expected verifier failure containing: $expected" >&2
        echo "$output" >&2
        exit 1
    fi
}

copy_fixture
python3 - "$TMP_ROOT/fixture/ios/Papercup/Info.plist" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
with path.open("rb") as handle:
    data = plistlib.load(handle)
data["NSAppTransportSecurity"] = {"NSAllowsArbitraryLoads": True}
with path.open("wb") as handle:
    plistlib.dump(data, handle)
PY
expect_failure "NSAllowsArbitraryLoads"

copy_fixture
printf '\nTODO: replace this before release\n' >> "$TMP_ROOT/fixture/store/LISTING.md"
expect_failure "placeholder marker"

copy_fixture
printf '\nContact <pending@example.com>\n' >> "$TMP_ROOT/fixture/store/LISTING.md"
expect_failure "placeholder marker"

copy_fixture
printf '\nHarmless fixture@local followed by > redirection\n' >> "$TMP_ROOT/fixture/store/LISTING.md"
PAPERCUP_IOS_RELEASE_ROOT="$TMP_ROOT/fixture" "$VERIFY"

copy_fixture
sed -i.bak 's/MARKETING_VERSION: "1.0.0"/MARKETING_VERSION: "0.1.0"/' \
    "$TMP_ROOT/fixture/ios/project.yml"
expect_failure "marketing version 1.0.0"

copy_fixture
python3 - "$TMP_ROOT/fixture/ios/Papercup/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
png = bytearray(path.read_bytes())
png[25] = 6
path.write_bytes(png)
PY
expect_failure "alpha channel"

copy_fixture
rm "$TMP_ROOT/fixture/tools/ios-ci.py"
expect_failure "missing release input: tools/ios-ci.py"

copy_fixture
mkdir -p "$TMP_ROOT/fixture/.github/workflows"
printf 'name: retired provider\n' > "$TMP_ROOT/fixture/.github/workflows/ci.yml"
expect_failure "workflows must remain retired"

copy_fixture
rm "$TMP_ROOT/fixture/docs/TESTFLIGHT-DEVICE-CHECKLIST.md"
expect_failure "missing release input: docs/TESTFLIGHT-DEVICE-CHECKLIST.md"

for guide in docs/BUILD.md docs/TESTFLIGHT-DEVICE-CHECKLIST.md; do
    copy_fixture
    printf '\nRun gh workflow run testflight.yml before acceptance.\n' >> "$TMP_ROOT/fixture/$guide"
    expect_failure "GitHub Actions execution instructions must remain retired"
    copy_fixture
    printf '\nGH  workflow  enable testflight.yml\n' >> "$TMP_ROOT/fixture/$guide"
    expect_failure "GitHub Actions execution instructions must remain retired"
done

echo "OK: native iOS release verifier rejects unsafe transport, placeholders, stale versions, transparent icons, missing execution inputs and restored Actions workflows/instructions"
