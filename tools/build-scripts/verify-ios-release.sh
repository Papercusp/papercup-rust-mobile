#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Static and toolchain checks for a public iPhone release.
set -euo pipefail

REPO_ROOT="${PAPERCUP_IOS_RELEASE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
REQUIRE_CURRENT_SDK=false

usage() {
    echo "Usage: $0 [--require-current-sdk]" >&2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --require-current-sdk) REQUIRE_CURRENT_SDK=true ;;
        -h|--help) usage; exit 0 ;;
        *) usage; echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

python3 - "$REPO_ROOT" <<'PY'
import plistlib
import json
import re
import struct
import sys
from pathlib import Path

root = Path(sys.argv[1])
required = [
    ".github/workflows/ci.yml",
    "ios/Papercup/Info.plist",
    "ios/Papercup/Papercup.entitlements",
    "ios/Papercup/Resources/PrivacyInfo.xcprivacy",
    "ios/Papercup/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json",
    "ios/Papercup/Sources/Papercup/AppLinks.swift",
    "ios/Papercup/Sources/Papercup/PapercupApp.swift",
    "ios/ExportOptions.plist",
    "ios/project.yml",
    "store/LISTING.md",
    "store/PRIVACY-POLICY.md",
    "store/APP-STORE-PRIVACY.md",
    "store/APP-STORE-REVIEW.md",
]
for relative in required:
    if not (root / relative).is_file():
        raise SystemExit(f"ERROR: missing release input: {relative}")

def load_plist(relative: str):
    with (root / relative).open("rb") as handle:
        return plistlib.load(handle)

def require(condition: bool, message: str):
    if not condition:
        raise SystemExit(f"ERROR: {message}")

info = load_plist("ios/Papercup/Info.plist")
ats = info.get("NSAppTransportSecurity", {})
require(ats.get("NSAllowsArbitraryLoads") is not True,
        "NSAllowsArbitraryLoads must not be enabled")
require(ats.get("NSAllowsLocalNetworking") is True,
        "the documented paired-desktop LAN path requires NSAllowsLocalNetworking")
require(info.get("CFBundleShortVersionString") == "$(MARKETING_VERSION)",
        "Info.plist marketing version must come from MARKETING_VERSION")
require(info.get("CFBundleVersion") == "$(CURRENT_PROJECT_VERSION)",
        "Info.plist build number must come from CURRENT_PROJECT_VERSION")
require("ElevenLabs" in info.get("NSMicrophoneUsageDescription", ""),
        "microphone usage text must disclose the optional cloud voice processor")
require("NSSpeechRecognitionUsageDescription" not in info,
        "do not declare unused Speech Recognition access")

project = (root / "ios/project.yml").read_text()
version_match = re.search(r'^\s*MARKETING_VERSION:\s*["\']?([^"\'\s]+)', project, re.MULTILINE)
build_match = re.search(r'^\s*CURRENT_PROJECT_VERSION:\s*["\']?([0-9]+)', project, re.MULTILINE)
require(version_match is not None and version_match.group(1) == "1.0.0",
        "public iOS release must use marketing version 1.0.0")
require(build_match is not None and int(build_match.group(1)) >= 1,
        "CURRENT_PROJECT_VERSION must be a positive integer")
for expected in [
    'PRODUCT_BUNDLE_IDENTIFIER: com.papercuspai.operator.mobile',
    'TARGETED_DEVICE_FAMILY: "1"',
    'SUPPORTS_MACCATALYST: NO',
    'CODE_SIGN_ENTITLEMENTS: Papercup/Papercup.entitlements',
    'APS_ENVIRONMENT: production',
]:
    require(expected in project, f"project.yml missing release setting: {expected}")
require("Sentry" not in project,
        "iPhone 1.0 must not link Sentry unless crash collection is added to every privacy disclosure")

entitlements = load_plist("ios/Papercup/Papercup.entitlements")
require(entitlements.get("aps-environment") == "$(APS_ENVIRONMENT)",
        "APNs entitlement must resolve from the Debug/Release build setting")

export = load_plist("ios/ExportOptions.plist")
require(export.get("method") == "app-store-connect",
        "ExportOptions.plist must target App Store Connect")
require(export.get("signingStyle") == "automatic",
        "the release script expects automatic signing")

manifest = load_plist("ios/Papercup/Resources/PrivacyInfo.xcprivacy")
require(manifest.get("NSPrivacyTracking") is False,
        "privacy manifest must explicitly disable tracking")
types = {entry.get("NSPrivacyCollectedDataType") for entry in manifest.get("NSPrivacyCollectedDataTypes", [])}
for data_type in [
    "NSPrivacyCollectedDataTypeAudioData",
    "NSPrivacyCollectedDataTypeOtherUserContent",
    "NSPrivacyCollectedDataTypeDeviceID",
]:
    require(data_type in types, f"privacy manifest missing {data_type}")
reasons = {
    entry.get("NSPrivacyAccessedAPIType"): set(entry.get("NSPrivacyAccessedAPITypeReasons", []))
    for entry in manifest.get("NSPrivacyAccessedAPITypes", [])
}
require("CA92.1" in reasons.get("NSPrivacyAccessedAPICategoryUserDefaults", set()),
        "privacy manifest missing the app-owned UserDefaults reason")

icon_dir = root / "ios/Papercup/Resources/Assets.xcassets/AppIcon.appiconset"
icon_catalog = json.loads((icon_dir / "Contents.json").read_text())
for entry in icon_catalog.get("images", []):
    filename = entry.get("filename")
    require(bool(filename), "every app icon catalog entry must name a file")
    icon_path = icon_dir / filename
    require(icon_path.is_file(), f"app icon catalog references missing file: {filename}")
    png = icon_path.read_bytes()
    require(png.startswith(b"\x89PNG\r\n\x1a\n") and len(png) >= 26,
            f"app icon must be a valid PNG: {filename}")
    width, height = struct.unpack(">II", png[16:24])
    color_type = png[25]
    require(color_type not in {4, 6},
            f"App Store icon contains an alpha channel: {filename}")
    logical_width, logical_height = (float(part) for part in entry["size"].split("x"))
    scale = int(entry["scale"].removesuffix("x"))
    expected = (round(logical_width * scale), round(logical_height * scale))
    require((width, height) == expected,
            f"app icon has wrong dimensions: {filename} is {width}x{height}, expected {expected[0]}x{expected[1]}")

app_links = (root / "ios/Papercup/Sources/Papercup/AppLinks.swift").read_text()
require('https://papercusp.com/mobile/privacy' in app_links,
        "the in-app privacy link must use the public mobile policy route")
require('https://papercusp.com/mobile/support' in app_links,
        "the in-app support link must use the public mobile support route")
swift_root = root / "ios/Papercup/Sources"
swift_text = "\n".join(path.read_text() for path in swift_root.rglob("*.swift"))
require("SentrySDK.start" not in swift_text,
        "iPhone 1.0 privacy answers declare no crash collection, so Sentry must remain absent")

all_release_text = "\n".join((root / relative).read_text() for relative in required if relative.endswith((".md", ".yml")))
require("https://papercusp.com/mobile/privacy" in all_release_text,
        "release materials must contain the final public privacy URL")
require("https://papercusp.com/mobile/support" in all_release_text,
        "release materials must contain the final public support URL")
# An angle-bracket email placeholder is one token on one line. Shell
# heredocs must not consume later Actions references and redirections.
markers = re.compile(r"\b(TODO|TBD|CHANGEME|YOUR_TEAM_ID|DRAFT)\b|<[^\r\n<>]+@[^\r\n<>]+>", re.IGNORECASE)
marker = markers.search(all_release_text)
require(marker is None, f"release materials contain placeholder marker: {marker.group(0) if marker else ''}")

workflow = (root / ".github/workflows/ci.yml").read_text()

def job_body(slug: str) -> str:
    match = re.search(
        rf"^  {re.escape(slug)}:\n(?P<body>.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)",
        workflow,
        re.MULTILINE | re.DOTALL,
    )
    require(match is not None, f"CI workflow missing {slug} job")
    return match.group("body")

def private_checkout(job: str, repository: str, label: str) -> str:
    blocks = [
        block
        for block in job.split("- uses: actions/checkout@v4")[1:]
        if f"repository: {repository}" in block
    ]
    require(len(blocks) == 1, f"{label} must have exactly one private checkout")
    block = blocks[0]
    require("persist-credentials: false" in block,
            f"{label} private checkout must not persist credentials")
    return block

token_repository = "${{ vars.TOKEN_KIT_REPOSITORY }}"
token_key = "${{ secrets.TOKEN_KIT_DEPLOY_KEY }}"
token_ref = "${{ steps.token-kit-ref.outputs.sha }}"
source_repository = "${{ vars.PAPERCUP_REPOSITORY }}"
source_key = "${{ secrets.PAPERCUP_DEPLOY_KEY }}"

ios_job = job_body("ios")
require("runs-on: macos-26" in ios_job,
        "iPhone release gate must run on the current macOS 26 image")
ios_token_checkout = private_checkout(ios_job, token_repository, "iOS token-kit")
for expected, message in [
    (f"ref: {token_ref}", "iOS token-kit checkout must use the pinned submodule revision"),
    (f"ssh-key: {token_key}", "iOS token-kit checkout must use its read-only deploy key"),
    ("path: libs/token-kit", "iOS token-kit checkout must populate the file dependency"),
]:
    require(expected in ios_token_checkout, message)
require(ios_job.index(f"repository: {token_repository}") < ios_job.index("npm ci"),
        "iOS token-kit checkout must happen before npm ci")

design_job = job_body("design-tokens")
design_token_checkout = private_checkout(design_job, token_repository, "design token-kit")
for expected, message in [
    (f"ref: {token_ref}", "design token-kit checkout must use the pinned submodule revision"),
    (f"ssh-key: {token_key}", "design token-kit checkout must use its read-only deploy key"),
    ("path: libs/token-kit", "design token-kit checkout must populate the file dependency"),
]:
    require(expected in design_token_checkout, message)
source_checkout = private_checkout(design_job, source_repository, "design source")
require(f"ssh-key: {source_key}" in source_checkout,
        "design source checkout must use its read-only deploy key")
require("path: ci/papercup" in source_checkout,
        "design source checkout must remain inside GITHUB_WORKSPACE")
require("PAPERCUP_DESIGN_TOKENS_DIR: ${{ github.workspace }}/ci/papercup/design-tokens" in design_job,
        "design-token drift check must use the in-workspace source checkout")
require('REQUIRE_PRIMITIVES_SOURCE: "1"' in design_job,
        "design-token drift check must fail closed when its source is missing")
require(design_job.index(f"repository: {token_repository}") < design_job.index("npm ci"),
        "design token-kit checkout must happen before npm ci")
require(design_job.index(f"repository: {source_repository}") < design_job.index("npm run tokens:check"),
        "design source checkout must happen before the drift check")
require(re.search(r"^\s+path:\s+\.\.(?:/|$)", workflow, re.MULTILINE) is None,
        "CI checkout paths must stay inside GITHUB_WORKSPACE")

print(f"OK: iOS release contract 1.0.0 ({root})")
PY

if [ "$REQUIRE_CURRENT_SDK" = true ]; then
    if [ "$(uname -s)" != "Darwin" ]; then
        echo "ERROR: --require-current-sdk requires macOS" >&2
        exit 1
    fi
    command -v xcrun >/dev/null || { echo "ERROR: xcrun not found" >&2; exit 1; }
    sdk_version="$(xcrun --sdk iphoneos --show-sdk-version)"
    sdk_major="${sdk_version%%.*}"
    if ! [[ "$sdk_major" =~ ^[0-9]+$ ]] || [ "$sdk_major" -lt 26 ]; then
        echo "ERROR: App Store uploads require the iOS 26 SDK or later; found $sdk_version" >&2
        exit 1
    fi
    echo "OK: current App Store SDK requirement satisfied (iPhoneOS $sdk_version)"
    xcodebuild -version
fi
