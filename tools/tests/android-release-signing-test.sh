#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Exercise the actual Gradle preflight with dummy inputs, never release secrets.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
JAVA_HOME="$("$ROOT/tools/build-scripts/resolve-java-home.sh")"
export JAVA_HOME
touch "$TMP/fixture.keystore"

# Assert the effective Android signing config too: accepting the preflight
# without passing the same password to the signer would reproduce the defect.
cat > "$TMP/signing-test.gradle" <<'GRADLE'
gradle.projectsEvaluated {
    def app = gradle.rootProject.project(':app')
    app.tasks.named('validateReleaseSigning').configure {
        doLast {
            def signing = app.extensions.getByName('android').signingConfigs.getByName('release')
            assert signing.storePassword == 'fixture-store-password'
            assert signing.keyAlias == 'fixture-alias'
            assert signing.keyPassword == System.getenv('PAPERCUP_TEST_EXPECTED_KEY_PASSWORD')
        }
    }
}
GRADLE

preflight() {
    local store="$1" password="$2" alias="$3" key_password="$4" expected="$5"
    env -u PAPERCUP_RELEASE_KEYSTORE -u PAPERCUP_RELEASE_KEYSTORE_PASSWORD \
        -u PAPERCUP_RELEASE_KEY_ALIAS -u PAPERCUP_RELEASE_KEY_PASSWORD \
        PAPERCUP_TEST_EXPECTED_KEY_PASSWORD="$expected" \
        "$ROOT/android/gradlew" -p "$ROOT/android" --console=plain --quiet \
        --init-script "$TMP/signing-test.gradle" :app:validateReleaseSigning \
        "-PPAPERCUP_RELEASE_KEYSTORE=$store" \
        "-PPAPERCUP_RELEASE_KEYSTORE_PASSWORD=$password" \
        "-PPAPERCUP_RELEASE_KEY_ALIAS=$alias" \
        "-PPAPERCUP_RELEASE_KEY_PASSWORD=$key_password" > "$TMP/result.log" 2>&1
}

expect_pass() {
    if ! preflight "$@"; then
        cat "$TMP/result.log" >&2
        echo 'FAIL: supported effective signing inputs were rejected' >&2
        exit 1
    fi
}
expect_failure() {
    local reason="$1"
    shift
    if preflight "$@"; then
        echo "FAIL: signing preflight accepted $reason" >&2
        exit 1
    fi
    grep -F 'Android release signing preflight failed' "$TMP/result.log" >/dev/null
    grep -F "$reason" "$TMP/result.log" >/dev/null
}

expect_pass "$TMP/fixture.keystore" fixture-store-password fixture-alias '' fixture-store-password
expect_pass "$TMP/fixture.keystore" fixture-store-password fixture-alias '  ' fixture-store-password
expect_pass "$TMP/fixture.keystore" fixture-store-password fixture-alias fixture-key-password fixture-key-password
expect_failure PAPERCUP_RELEASE_KEYSTORE '' fixture-store-password fixture-alias '' fixture-store-password
expect_failure PAPERCUP_RELEASE_KEYSTORE_PASSWORD "$TMP/fixture.keystore" '  ' fixture-alias '' fixture-store-password
expect_failure PAPERCUP_RELEASE_KEY_ALIAS "$TMP/fixture.keystore" fixture-store-password '  ' '' fixture-store-password
expect_failure 'keystore does not exist' "$TMP/missing.keystore" fixture-store-password fixture-alias '' fixture-store-password
echo 'Android Gradle signing preflight: 3 supported configurations passed; 4 invalid configurations rejected'
