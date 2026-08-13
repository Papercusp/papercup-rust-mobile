#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Regression tests for tools/build-scripts/resolve-java-home.sh.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RESOLVER="$REPO_ROOT/tools/build-scripts/resolve-java-home.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

make_fake_jdk() {
    local home="$1"
    local version="$2"
    mkdir -p "$home/bin"
    printf '%s\n' '#!/usr/bin/env bash' "printf 'openjdk version \"$version\"\\n' >&2" > "$home/bin/java"
    chmod +x "$home/bin/java"
}

assert_path() {
    local expected="$1"
    local actual="$2"
    [[ "$actual" == "$expected" ]] || fail "expected '$expected', got '$actual'"
}

JDK11="$TMP_ROOT/jdk-11"
JDK17="$TMP_ROOT/jdk-17"
JDK21="$TMP_ROOT/jdk-21"
make_fake_jdk "$JDK11" '11.0.24'
make_fake_jdk "$JDK17" '17.0.12'
make_fake_jdk "$JDK21" '21.0.4'

# An explicit valid JAVA_HOME remains authoritative over discovered candidates.
resolved="$(JAVA_HOME="$JDK17" PAPERCUP_JAVA_CANDIDATES="$JDK21" PAPERCUP_SKIP_AMBIENT_JAVA=1 "$RESOLVER")"
assert_path "$JDK17" "$resolved"

# An obsolete explicit JAVA_HOME is rejected, then the dynamic candidate wins.
resolved="$(JAVA_HOME="$JDK11" PAPERCUP_JAVA_CANDIDATES="$JDK21" PAPERCUP_SKIP_AMBIENT_JAVA=1 "$RESOLVER")"
assert_path "$JDK21" "$resolved"

# A versioned Android Studio JBR is found without a hard-coded Snap revision.
JBR="$TMP_ROOT/android-studio/999/jbr"
make_fake_jdk "$JBR" '17.0.13'
resolved="$(JAVA_HOME= PAPERCUP_JAVA_SEARCH_ROOTS="$TMP_ROOT/android-studio" PAPERCUP_SKIP_AMBIENT_JAVA=1 "$RESOLVER")"
assert_path "$JBR" "$resolved"

# Failure is actionable and names the discovered stale candidate.
if diagnostics="$(JAVA_HOME= PAPERCUP_JAVA_CANDIDATES="$JDK11" PAPERCUP_SKIP_AMBIENT_JAVA=1 "$RESOLVER" 2>&1)"; then
    fail 'an obsolete Java 11 candidate unexpectedly resolved'
fi
grep -F "no Java 17+ runtime" <<<"$diagnostics" >/dev/null || fail 'missing minimum-version error'
grep -F "$JDK11" <<<"$diagnostics" >/dev/null || fail 'missing candidate diagnostics'

echo 'resolve-java-home tests: 4 passed'
