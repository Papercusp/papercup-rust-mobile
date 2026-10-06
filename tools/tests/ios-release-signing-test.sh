#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# TestFlight signing route (WI-10006899): exercise the real CI signing helper,
# the real release script and the workflow contract with fixture inputs only —
# never Apple secrets. Subject paths are overridable so a mutated COPY can be
# checked without touching the tree.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SIGNING="${PAPERCUP_TEST_SIGNING_SCRIPT:-$ROOT/tools/build-scripts/ios-ci-signing.sh}"
RELEASE="${PAPERCUP_TEST_RELEASE_SCRIPT:-$ROOT/tools/build-scripts/release-ios.sh}"
WORKFLOW="${PAPERCUP_TEST_WORKFLOW:-$ROOT/.github/workflows/testflight.yml}"
PROJECT="${PAPERCUP_TEST_PROJECT_YML:-$ROOT/ios/project.yml}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

TEAM=ABCDE12345
BUNDLE=com.papercuspai.operator.mobile
PROFILE_NAME='Papercusp App Store'

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# ---------------------------------------------------------------- secrets gate
fixture_b64="$(printf 'fixture' | base64)"
run_gate() {
    env -i PATH="$PATH" HOME="$TMP" "$@" bash "$SIGNING" require-secrets > "$TMP/gate.log" 2>&1
}
all_secrets=(
    "APPLE_TEAM_ID=$TEAM"
    "IOS_DIST_CERT_P12_BASE64=$fixture_b64"
    "IOS_DIST_CERT_PASSWORD=fixture-password"
    "IOS_APPSTORE_PROFILE_BASE64=$fixture_b64"
    "ASC_API_KEY_ID=FIXTUREKEY"
    "ASC_API_ISSUER_ID=00000000-0000-0000-0000-000000000000"
    "ASC_API_KEY_P8_BASE64=$fixture_b64"
)

if run_gate; then fail 'secrets gate accepted an empty environment'; fi
[ "$(grep -c '^MISSING_SECRET: ' "$TMP/gate.log")" -eq 7 ] || fail 'secrets gate must name all 7 missing secrets'

without_issuer=()
for pair in "${all_secrets[@]}"; do
    [ "${pair%%=*}" = ASC_API_ISSUER_ID ] || without_issuer+=("$pair")
done
if run_gate "${without_issuer[@]}"; then fail 'secrets gate accepted a missing issuer ID'; fi
grep -qx 'MISSING_SECRET: ASC_API_ISSUER_ID' "$TMP/gate.log" || fail 'missing issuer ID was not named'
[ "$(grep -c '^MISSING_SECRET: ' "$TMP/gate.log")" -eq 1 ] || fail 'secrets gate named a present secret as missing'

if run_gate "${all_secrets[@]}" APPLE_TEAM_ID=abc; then fail 'secrets gate accepted a malformed team ID'; fi
grep -qx 'INVALID_SECRET: APPLE_TEAM_ID' "$TMP/gate.log" || fail 'malformed team ID was not named'

if run_gate "${all_secrets[@]}" 'IOS_DIST_CERT_P12_BASE64=not base64!!'; then
    fail 'secrets gate accepted a certificate that is not base64'
fi
grep -qx 'INVALID_SECRET: IOS_DIST_CERT_P12_BASE64' "$TMP/gate.log" || fail 'non-base64 certificate was not named'

run_gate "${all_secrets[@]}" || { cat "$TMP/gate.log" >&2; fail 'secrets gate rejected a complete secret set'; }

# ----------------------------------------------------------- profile validation
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/signer.key" -out "$TMP/signer.pem" \
    -subj '/CN=Papercup profile fixture' -days 2 >/dev/null 2>&1
openssl x509 -in "$TMP/signer.pem" -outform der -out "$TMP/dist.der"
cert_sha1="$(openssl x509 -in "$TMP/signer.pem" -noout -fingerprint -sha1 | sed -e 's/^.*=//' -e 's/://g' | tr 'a-f' 'A-F')"

make_profile() {
    local variant="$1"
    python3 - "$variant" "$TMP/dist.der" "$TMP/profile-$variant.plist" "$TEAM" "$BUNDLE" "$PROFILE_NAME" <<'PY'
import datetime
import plistlib
import sys

variant, cert_path, out, team, bundle, name = sys.argv[1:]
now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None, microsecond=0)
profile = {
    "Name": name,
    "UUID": "11111111-2222-3333-4444-555555555555",
    "TeamIdentifier": [team],
    "ExpirationDate": now + datetime.timedelta(days=300),
    "DeveloperCertificates": [open(cert_path, "rb").read()],
    "Entitlements": {
        "application-identifier": f"{team}.{bundle}",
        "get-task-allow": False,
        "aps-environment": "production",
    },
}
if variant == "wrong-team":
    profile["TeamIdentifier"] = ["ZZZZZ99999"]
elif variant == "wrong-app":
    profile["Entitlements"]["application-identifier"] = f"{team}.com.example.other"
elif variant == "development":
    profile["Entitlements"]["get-task-allow"] = True
    profile["ProvisionedDevices"] = ["00008110-000000000000001E"]
elif variant == "push-development":
    profile["Entitlements"]["aps-environment"] = "development"
elif variant == "expired":
    profile["ExpirationDate"] = now - datetime.timedelta(days=1)
with open(out, "wb") as handle:
    plistlib.dump(profile, handle)
PY
    openssl smime -sign -binary -nodetach -outform der -signer "$TMP/signer.pem" -inkey "$TMP/signer.key" \
        -in "$TMP/profile-$variant.plist" -out "$TMP/profile-$variant.mobileprovision"
}

check() {
    PAPERCUP_PROFILE_DECODER=openssl bash "$SIGNING" check-profile "$1" "$TEAM" > "$TMP/check.out" 2> "$TMP/check.err"
}

make_profile good
check "$TMP/profile-good.mobileprovision" || { cat "$TMP/check.err" >&2; fail 'a valid App Store profile was rejected'; }
printf '%s\t%s\t%s\n' "$PROFILE_NAME" 11111111-2222-3333-4444-555555555555 "$cert_sha1" > "$TMP/check.expected"
cmp -s "$TMP/check.out" "$TMP/check.expected" || fail "profile summary was $(cat "$TMP/check.out")"

expect_rejected() {
    local variant="$1" reason="$2"
    make_profile "$variant"
    if check "$TMP/profile-$variant.mobileprovision"; then fail "accepted a $variant profile"; fi
    grep -F "PROFILE_REJECTED: " "$TMP/check.err" | grep -qF "$reason" || {
        cat "$TMP/check.err" >&2
        fail "$variant profile was not rejected for: $reason"
    }
}
expect_rejected wrong-team 'is not ABCDE12345'
expect_rejected wrong-app 'not ABCDE12345.com.papercuspai.operator.mobile'
expect_rejected development 'lists devices'
expect_rejected development 'allows debugging'
expect_rejected push-development 'production Push Notifications'
expect_rejected expired 'expired'

printf 'not a profile' > "$TMP/garbage.mobileprovision"
if check "$TMP/garbage.mobileprovision"; then fail 'accepted an unsigned profile'; fi
grep -qF 'is not a signed provisioning profile' "$TMP/check.err" || fail 'unsigned profile error was not named'

# ------------------------------------------------- release script signing modes
FIX="$TMP/repo"
mkdir -p "$FIX/tools/build-scripts" "$FIX/ios" "$TMP/bin" "$TMP/log"
cp "$RELEASE" "$FIX/tools/build-scripts/release-ios.sh"
cp "$ROOT/ios/ExportOptions.plist" "$FIX/ios/ExportOptions.plist"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FIX/tools/build-scripts/verify-ios-release.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FIX/tools/build-scripts/build-ios.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/xcodegen"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/rustup"
cat > "$TMP/bin/security" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LOG_DIR/security.calls"
if [ "$1" = find-identity ]; then
    echo '  1) 0123456789ABCDEF0123456789ABCDEF01234567 "Apple Distribution: Fixture (ABCDE12345)"'
fi
SH
cat > "$TMP/bin/xcodebuild" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$LOG_DIR/xcodebuild$1.args"
if [ "$1" = -exportArchive ]; then
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -exportPath) out="$2"; shift ;;
            -exportOptionsPlist) options="$2"; shift ;;
        esac
        shift
    done
    cp "$options" "$LOG_DIR/export-options.plist"
    mkdir -p "$out"
    touch "$out/Papercusp.ipa"
fi
SH
chmod +x "$FIX/tools/build-scripts/"*.sh "$TMP/bin/"*

release() {
    rm -rf "$TMP/log" "$TMP/release"
    mkdir -p "$TMP/log"
    env -u PAPERCUP_SIGNING_STYLE -u PAPERCUP_PROVISIONING_PROFILE -u PAPERCUP_CI_KEYCHAIN \
        PATH="$TMP/bin:$PATH" LOG_DIR="$TMP/log" PAPERCUP_DEVELOPMENT_TEAM="$TEAM" \
        PAPERCUP_RELEASE_DIR="$TMP/release" "$@" \
        bash "$FIX/tools/build-scripts/release-ios.sh" export > "$TMP/release.log" 2>&1
}

keychain="$TMP/ci.keychain-db"
release PAPERCUP_SIGNING_STYLE=manual "PAPERCUP_PROVISIONING_PROFILE=$PROFILE_NAME" \
    "PAPERCUP_CI_KEYCHAIN=$keychain" || { cat "$TMP/release.log" >&2; fail 'manual signing export failed'; }
archive="$TMP/log/xcodebuildarchive.args"
for expected in CODE_SIGN_STYLE=Manual 'CODE_SIGN_IDENTITY=Apple Distribution' \
    "PAPERCUP_APP_PROVISIONING_PROFILE=$PROFILE_NAME" "OTHER_CODE_SIGN_FLAGS=--keychain $keychain" \
    "DEVELOPMENT_TEAM=$TEAM"; do
    grep -qxF "$expected" "$archive" || fail "manual archive is missing: $expected"
done
if grep -q '^PROVISIONING_PROFILE_SPECIFIER=' "$archive"; then
    fail 'a global profile specifier also reaches PapercupCore and the Swift packages'
fi
if grep -qx -- -allowProvisioningUpdates "$archive" "$TMP/log/xcodebuild-exportArchive.args"; then
    fail 'manual signing must not ask Xcode to manage profiles'
fi
grep -qxF "find-identity -v -p codesigning $keychain" "$TMP/log/security.calls" \
    || fail 'manual signing must look for the identity in the CI keychain'
python3 - "$TMP/log/export-options.plist" "$TEAM" "$BUNDLE" "$PROFILE_NAME" <<'PY' || fail 'manual export options are wrong'
import plistlib
import sys

path, team, bundle, name = sys.argv[1:]
options = plistlib.load(open(path, "rb"))
assert options["signingStyle"] == "manual", options
assert options["teamID"] == team, options
assert options["signingCertificate"] == "Apple Distribution", options
assert options["provisioningProfiles"] == {bundle: name}, options
assert options["method"] == "app-store-connect", "manual export must keep the tracked method"
PY

if release PAPERCUP_SIGNING_STYLE=manual; then fail 'manual signing ran without a profile name'; fi
grep -qF PAPERCUP_PROVISIONING_PROFILE "$TMP/release.log" || fail 'missing profile name was not named'
[ ! -e "$TMP/log/xcodebuildarchive.args" ] || fail 'xcodebuild ran before the missing profile was refused'

if release PAPERCUP_SIGNING_STYLE=bogus; then fail 'an unknown signing style was accepted'; fi
grep -qF 'must be automatic or manual' "$TMP/release.log" || fail 'unknown signing style was not named'

release || { cat "$TMP/release.log" >&2; fail 'automatic signing export failed'; }
grep -qx -- -allowProvisioningUpdates "$TMP/log/xcodebuildarchive.args" || fail 'automatic archive lost provisioning updates'
if grep -q '^CODE_SIGN_STYLE=' "$TMP/log/xcodebuildarchive.args"; then fail 'automatic archive overrode the signing style'; fi
cmp -s "$TMP/log/export-options.plist" "$ROOT/ios/ExportOptions.plist" || fail 'automatic export must use the tracked ExportOptions.plist'

# ------------------------------------------------------------ project contract
python3 - "$PROJECT" <<'PY' || fail 'project.yml must give only the app target the CI profile variable'
import sys

text = open(sys.argv[1]).read()
line = "PROVISIONING_PROFILE_SPECIFIER: $(PAPERCUP_APP_PROVISIONING_PROFILE)"
assert text.count(line) == 1, "expected exactly one app-target profile variable"
app = text.split("\n  Papercup:\n", 1)[1].split("\n  PapercupTests:\n", 1)[0]
assert line in app, "the profile variable must sit on the Papercup app target"
PY

# ----------------------------------------------------------- workflow contract
python3 - "$WORKFLOW" <<'PY' || fail 'TestFlight workflow contract broken'
import re
import sys

text = open(sys.argv[1]).read()
trigger = text.split("\non:\n", 1)[1].split("\npermissions:", 1)[0]
assert "workflow_dispatch:" in trigger, "TestFlight must be dispatchable"
for automatic in ("push:", "pull_request:", "schedule:"):
    assert automatic not in trigger, f"every run spends a build number; {automatic} is not allowed"
assert "\npermissions:\n  contents: read\n" in text, "workflow token must be read-only"
assert "runs-on: macos-26" in text, "must build with the iOS 26 SDK runner"

gate = text.index("ios-ci-signing.sh require-secrets")
for expensive in ("dtolnay/rust-toolchain", "npm ci", "ios-ci-signing.sh install", "release-ios.sh export"):
    assert gate < text.index(expensive), f"missing secrets must fail before {expensive}"
gate_step = text[text.rindex("- name:", 0, gate):gate]
secrets = ("APPLE_TEAM_ID", "IOS_DIST_CERT_P12_BASE64", "IOS_DIST_CERT_PASSWORD",
           "IOS_APPSTORE_PROFILE_BASE64", "ASC_API_KEY_ID", "ASC_API_ISSUER_ID", "ASC_API_KEY_P8_BASE64")
for name in secrets:
    assert f"{name}: ${{{{ secrets.{name} }}}}" in gate_step, f"secrets gate does not see {name}"

for line in text.splitlines():
    if "secrets." in line:
        assert re.fullmatch(r"\s+([A-Z0-9_]+|ssh-key): \$\{\{ secrets\.[A-Z0-9_]+ \}\}", line), \
            f"secrets may only enter through step env/inputs, never a run script: {line.strip()}"

cleanup = text.index("ios-ci-signing.sh cleanup")
cleanup_step = text[text.rindex("- name:", 0, cleanup):cleanup]
assert "if: always()" in cleanup_step, "signing material must be removed even when the build fails"

upload = text.index("release-ios.sh upload")
upload_step = text[text.rindex("- name:", 0, upload):upload]
assert "if: inputs.upload" in upload_step, "upload must be optional"

artifact = text.split("actions/upload-artifact", 1)[1].split("\n      - name:", 1)[0]
for private in ("signing", "private_keys", ".p8", ".p12", "mobileprovision", "keychain"):
    assert private not in artifact, f"artifacts must not retain signing material ({private})"
PY

echo 'OK: TestFlight signing route verified (secrets gate, profile checks, release modes, project and workflow contract)'
