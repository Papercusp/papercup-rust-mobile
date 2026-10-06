#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Fixture archives for tools/build-scripts/validate-ios-archive.py (P-009).
# Runs on Linux: the validator is pure Python, so every rejection path is
# exercised without a Mac. Each case mutates one fact of a valid archive.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VALIDATOR="${PAPERCUP_TEST_ARCHIVE_VALIDATOR:-$REPO_ROOT/tools/build-scripts/validate-ios-archive.py}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SHA=0123456789abcdef0123456789abcdef01234567
fail() { echo "FAIL: $*" >&2; exit 1; }

# make_archive <dir> [key=value ...] builds a valid unsigned candidate, then
# applies the named mutations.
make_archive() {
    python3 - "$@" <<'PY'
import plistlib, struct, sys
from pathlib import Path
root = Path(sys.argv[1]); opts = dict(a.split("=", 1) for a in sys.argv[2:])
app = root / "Products/Applications/Papercup.app"
app.mkdir(parents=True)
bundle = opts.get("bundle", "com.papercuspai.operator.mobile")
plistlib.dump({"ApplicationProperties": {"ApplicationPath": opts.get("apppath", "Applications/Papercup.app"),
               "CFBundleIdentifier": bundle}, "ArchiveVersion": 2}, (root / "Info.plist").open("wb"))
info = {"CFBundleIdentifier": bundle, "CFBundleExecutable": "Papercup",
        "CFBundleShortVersionString": opts.get("version", "1.0.0"), "CFBundleVersion": opts.get("build", "7"),
        "DTPlatformName": opts.get("platform_name", "iphoneos"), "DTSDKName": opts.get("sdk_name", "iphoneos26.0"),
        "DTPlatformVersion": opts.get("plist_sdk", "26.0"), "MinimumOSVersion": opts.get("minos", "17.0")}
plistlib.dump(info, (app / "Info.plist").open("wb"), fmt=plistlib.FMT_BINARY)
def ver(text):
    major, minor = (text.split(".") + ["0"])[:2]
    return int(major) << 16 | int(minor) << 8
cmd = struct.pack("<IIIIII", 0x32, 24, int(opts.get("macho_platform", "2")), ver("17.0"), ver(opts.get("macho_sdk", "26.0")), 0)
thin = struct.pack("<IiiIIII", 0xFEEDFACF, int(opts.get("cpu", str(0x0100000C))), 0, 2, 1, len(cmd), 0) + struct.pack("<I", 0) + cmd
if opts.get("fat") == "1":
    other = struct.pack("<IiiIIII", 0xFEEDFACF, 0x01000007, 3, 2, 0, 0, 0) + b"\0" * 4
    header = struct.pack(">II", 0xCAFEBABE, 2)
    first = 8 + 2 * 20
    header += struct.pack(">iiIII", 0x01000007, 3, first, len(other), 0)
    header += struct.pack(">iiIII", 0x0100000C, 0, first + len(other), len(thin), 0)
    thin = header + other + thin
if opts.get("no_exec") != "1":
    (app / "Papercup").write_bytes(thin)
if opts.get("no_privacy") != "1":
    plistlib.dump({"NSPrivacyTracking": opts.get("tracking") == "1"}, (app / "PrivacyInfo.xcprivacy").open("wb"))
if "framework" in opts:
    (app / "Frameworks" / opts["framework"]).mkdir(parents=True)
if opts.get("signed") == "1":
    (app / "_CodeSignature").mkdir(); (app / "_CodeSignature/CodeResources").write_bytes(b"x")
    (app / "embedded.mobileprovision").write_bytes(b"x")
PY
}

case_n=0
accept() {
    case_n=$((case_n + 1)); local dir="$TMP/ok$case_n"; make_archive "$dir" "${@:3}"
    local args; read -r -a args <<< "$2"
    python3 "$VALIDATOR" "$dir" --source-sha "$SHA" --manifest "$dir.json" ${args[@]+"${args[@]}"} \
        > "$TMP/out" 2>&1 || { cat "$TMP/out" >&2; fail "$1 was rejected"; }
}
reject() {
    case_n=$((case_n + 1)); local dir="$TMP/bad$case_n" label="$1" expect="$2" args; make_archive "$dir" "${@:4}"
    read -r -a args <<< "$3"
    if python3 "$VALIDATOR" "$dir" ${args[@]+"${args[@]}"} > "$TMP/out" 2>&1; then
        fail "$label was accepted"
    fi
    grep -qF -- "$expect" "$TMP/out" || { cat "$TMP/out" >&2; fail "$label failed for the wrong reason"; }
}

accept 'valid unsigned candidate' ''
python3 - "$TMP/ok1.json" "$SHA" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
assert m["sourceSha"] == sys.argv[2] and m["version"] == "1.0.0" and m["build"] == "7", m
assert m["executableSdk"] == "26.0.0" and m["signed"] is False, m
PY
accept 'fat executable with an arm64 device slice' '' fat=1
accept 'signed TestFlight archive' '--require-signed --build 7' signed=1

S="--source-sha $SHA"
reject 'missing source revision' '--source-sha' ''
reject 'short source revision' '40-hex' '--source-sha abc123'
reject 'wrong bundle id' 'bundle id' "$S" bundle=com.example.other
reject 'non-app archive' 'ApplicationPath' "$S" apppath=usr/local/lib
reject 'unresolved marketing version' 'unresolved' "$S" 'version=$(MARKETING_VERSION)'
reject 'marketing version drift' '!= 1.0.0' "$S" version=1.0.1
reject 'non-numeric build' 'positive integer' "$S" build=1.2
reject 'build number mismatch' 'requested build 8' "$S --build 8"
reject 'simulator platform in plist' 'iphoneos device' "$S" platform_name=iphonesimulator
reject 'old SDK in plist' 'requires 26+' "$S" plist_sdk=18.2
reject 'deployment target drift' 'deployment target' "$S" minos=16.0
reject 'missing executable' 'executable is missing' "$S" no_exec=1
reject 'simulator executable' 'not iOS device' "$S" macho_platform=7
reject 'old SDK in executable' 'links SDK' "$S" macho_sdk=18.2
reject 'x86_64 executable' 'not arm64' "$S" cpu=$((0x01000007))
reject 'missing privacy manifest' 'PrivacyInfo.xcprivacy' "$S" no_privacy=1
reject 'tracking privacy manifest' 'no tracking' "$S" tracking=1
reject 'embedded Sentry' 'Sentry framework' "$S" framework=Sentry.framework
reject 'unsigned TestFlight archive' 'not code-signed' "$S --require-signed"

echo "OK: validate-ios-archive fixtures ($case_n cases)"
