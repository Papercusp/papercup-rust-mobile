#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# P-016 acceptance runner (iphone-public-release-2026-08-11 D-014, WI-10006858): the iPhone
# app against a real BYOC cloud workspace, reached only through the portal's device-http
# relay, <portal>/api/workspaces/<id>/api/device/<route> (android-public-release-2026-10-01
# D-013). The phone half needs P-015 (sealed Noise channel, iOS + shared Rust).
#
# Each check prints one line `P016_CHECK <check> PASS|FAIL <code> <detail>`, appends one
# JSON line to $P016_EVIDENCE, and exits 1 on FAIL, 2 on a usage error, and 3 when this host
# cannot run the check.
#
#   preflight <workspace-id>        The relay route answers for the workspace, and the workspace
#                                   is BYOC. Needs no phone and no credential.
#   pair-payload <workspace-id> <qr-json-file>
#                                   A pair QR minted on the cloud desktop (Settings -> Remote
#                                   access) points at the relay and carries the machine Noise key.
#   phone                           macOS only. The paired XCUITest journeys run against the cloud
#                                   payload through tools/run-ios-uitests.sh.
#   offline                         Connector-offline drill: stop the connector, run the phone-side
#                                   offline check, ALWAYS restart the connector, then run the
#                                   recovery check.
#   no-plaintext <canary>           The canary the phone sent is absent from the control plane and
#                                   present on the machine (the positive control).
#   classify <status> <error-code>  Map one relay response to a verdict. Pure; the tests use it.
#
# Environment:
#   P016_PORTAL           portal origin (default https://app.papercusp.com)
#   P016_EXPECT_HOSTING   byoc (default) | papercusp
#   P016_EVIDENCE         JSONL evidence file (default ./p016-evidence.jsonl)
#   offline:       P016_CONNECTOR_STOP_CMD, P016_CONNECTOR_START_CMD, P016_CHECK_OFFLINE_CMD and
#                  P016_CHECK_RECOVERED_CMD (all required; each check command's exit status is
#                  its verdict)
#   no-plaintext:  P016_MACHINE_SCAN_CMD (required; prints the canary hit count on the machine),
#                  P016_CONTROL_PLANE_UNIT (default papercusp-hosted-control-plane.service),
#                  P016_SINCE (default "2 hours ago"), P016_JOURNAL_CMD (replaces the journalctl
#                  read), P016_EXTRA_SCAN_CMD (optional; prints a control-plane hit count)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORTAL="${P016_PORTAL:-https://app.papercusp.com}"
PORTAL="${PORTAL%/}"
EXPECT_HOSTING="${P016_EXPECT_HOSTING:-byoc}"
EVIDENCE="${P016_EVIDENCE:-./p016-evidence.jsonl}"

usage() {
    sed -n '3,37p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

# record <check> <PASS|FAIL> <code> <detail...>: print, append evidence, return the verdict.
record() {
    local check="$1" verdict="$2" code="$3"
    shift 3
    local detail="$*"
    echo "P016_CHECK $check $verdict $code $detail"
    python3 - "$EVIDENCE" "$check" "$verdict" "$code" "$detail" "$PORTAL" <<'PY'
import datetime, json, sys
path, check, verdict, code, detail, portal = sys.argv[1:7]
row = {
    "at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
    "check": check, "verdict": verdict, "code": code, "detail": detail, "portal": portal,
}
with open(path, "a", encoding="utf-8") as f:
    f.write(json.dumps(row) + "\n")
PY
    [ "$verdict" = PASS ]
}

# The `error` field of a JSON body, or `-` when the body is not a JSON object with one.
json_error() {
    python3 - "$1" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        body = json.load(f)
    code = body.get("error") if isinstance(body, dict) else None
    print(code if isinstance(code, str) and code else "-")
except Exception:
    print("-")
PY
}

# classify <http-status> <error-code> -> "<PASS|FAIL> <code> <detail>".
# Relay order (hosted-app-relay.ts handleHostedDeviceRelay): unparsable path -> 404 not_found;
# BYOC hosting -> 403 byoc_plaintext_relay_refused, before any route or token check; then
# 401 device_token_required. A workspace whose hosting cannot be resolved (unknown id) falls
# through to that same 401, so 401 never proves the workspace exists.
classify() {
    local status="$1" code="$2"
    case "$status:$code" in
        403:byoc_plaintext_relay_refused)
            if [ "$EXPECT_HOSTING" = byoc ]; then
                echo "PASS relay_live_byoc device-http answers and refuses plaintext on a BYOC workspace"
            else
                echo "FAIL hosting_mismatch the workspace is BYOC but P016_EXPECT_HOSTING=$EXPECT_HOSTING"
            fi ;;
        401:device_token_required)
            if [ "$EXPECT_HOSTING" = papercusp ]; then
                echo "PASS relay_live_unconfirmed_hosting device-http answers; an unknown workspace id answers the same, so hosting is unconfirmed"
            else
                echo "FAIL not_byoc device-http answers but the workspace is Papercusp-hosted or unknown to the control plane; P-016 needs a BYOC workspace"
            fi ;;
        401:portal_auth_required)
            echo "FAIL ingress_missing the portal catch-all answered: the public ingress does not route /api/workspaces/<id>/api/device/* to the hosted control plane" ;;
        404:not_found)
            echo "FAIL relay_path_rejected the relay could not parse the device path" ;;
        404:-)
            echo "FAIL relay_route_absent a non-JSON 404: the hosted control plane build has no device-http route" ;;
        503:workspace_offline)
            echo "FAIL connector_offline the workspace connector is offline" ;;
        000:*)
            echo "FAIL unreachable no HTTP response from $PORTAL" ;;
        *)
            echo "FAIL unexpected status=$status error=$code" ;;
    esac
}

cmd_classify() {
    [ $# -eq 2 ] || usage
    classify "$1" "$2"
}

cmd_preflight() {
    [ $# -eq 1 ] || usage
    local ws="$1" tmp status code verdict
    tmp="$(mktemp)"
    status="$(curl -sS -m 20 -o "$tmp" -w '%{http_code}' "$PORTAL/api/workspaces/$ws/api/device/heartbeat" 2>/dev/null)" || status=000
    code="$(json_error "$tmp")"
    rm -f "$tmp"
    verdict="$(classify "$status" "$code")"
    # shellcheck disable=SC2086 # deliberate split: verdict, code, then the detail words
    record preflight $verdict "(workspace=$ws status=$status error=$code)"
}

# check_pair_payload <workspace-id> <json-string> -> "<PASS|FAIL> <code> <detail>"
check_pair_payload() {
    python3 - "$1" "$2" "$PORTAL" "$EXPECT_HOSTING" <<'PY'
import base64, binascii, json, sys
ws, raw, portal, hosting = sys.argv[1:5]
try:
    p = json.loads(raw)
except ValueError:
    print("FAIL payload_not_json the pair payload is not JSON"); sys.exit()
if not isinstance(p, dict):
    print("FAIL payload_not_object the pair payload is not a JSON object"); sys.exit()
want = f"{portal}/api/workspaces/{ws}"
server = str(p.get("server", "")).rstrip("/")
if server != want:
    print(f"FAIL server_not_relay server={server or '-'} want={want} (a private or LAN address cannot reach a cloud VM)"); sys.exit()
if not p.get("pairToken"):
    print("FAIL pair_token_missing the payload has no pairToken"); sys.exit()
if not p.get("workspaceId"):
    print("FAIL workspace_id_missing the payload has no workspaceId"); sys.exit()
key = p.get("noiseKey")
if hosting == "byoc":
    if not key:
        print("FAIL noise_key_missing a BYOC pair payload must carry the machine noiseKey (D-013 #6)"); sys.exit()
    try:
        raw_key = base64.b64decode(key, validate=True)
    except (binascii.Error, ValueError):
        print("FAIL noise_key_not_base64 noiseKey is not valid base64"); sys.exit()
    if len(raw_key) != 32:
        print(f"FAIL noise_key_length noiseKey decodes to {len(raw_key)} bytes, want 32"); sys.exit()
print("PASS pair_payload_relay server is the relay URL" + (" and noiseKey is a 32-byte key" if key else ""))
PY
}

cmd_pair_payload() {
    [ $# -eq 2 ] || usage
    local verdict
    [ -r "$2" ] || { echo "ERROR: cannot read $2" >&2; exit 2; }
    verdict="$(check_pair_payload "$1" "$(cat "$2")")"
    # shellcheck disable=SC2086
    record pair-payload $verdict "(workspace=$1)"
}

cmd_phone() {
    if [ "$(uname -s)" != Darwin ]; then
        record phone FAIL requires_macos "the XCUITest journeys need Xcode; run on the macOS CI runner or a Mac" || exit 3
    fi
    if [ -z "${PAPERCUP_PAIR_PAYLOAD:-}" ] && [ -z "${PAPERCUP_MINT_PAIR_PAYLOAD_CMD:-}" ]; then
        echo "ERROR: set PAPERCUP_PAIR_PAYLOAD (a cloud QR payload) or PAPERCUP_MINT_PAIR_PAYLOAD_CMD" >&2
        exit 2
    fi
    if [ -n "${PAPERCUP_PAIR_PAYLOAD:-}" ] && [ -n "${P016_WORKSPACE:-}" ]; then
        local verdict
        verdict="$(check_pair_payload "$P016_WORKSPACE" "$PAPERCUP_PAIR_PAYLOAD")"
        # shellcheck disable=SC2086
        record pair-payload $verdict "(workspace=$P016_WORKSPACE)"
    fi
    if bash "$REPO_ROOT/tools/run-ios-uitests.sh"; then
        record phone PASS uitests_passed "paired journeys passed against $PORTAL"
    else
        record phone FAIL uitests_failed "tools/run-ios-uitests.sh exited non-zero"
    fi
}

cmd_offline() {
    local v
    for v in P016_CONNECTOR_STOP_CMD P016_CONNECTOR_START_CMD P016_CHECK_OFFLINE_CMD P016_CHECK_RECOVERED_CMD; do
        [ -n "${!v:-}" ] || { echo "ERROR: $v is required for the offline drill" >&2; exit 2; }
    done
    local rc=0
    # Global, not local: the EXIT trap runs after this function's locals are gone.
    P016_RESTARTED=0
    restart() {
        [ "$P016_RESTARTED" = 1 ] && return 0
        P016_RESTARTED=1
        bash -c "$P016_CONNECTOR_START_CMD"
    }
    trap 'restart || echo "ERROR: connector restart FAILED; restart it by hand" >&2' EXIT
    if ! bash -c "$P016_CONNECTOR_STOP_CMD"; then
        record offline FAIL stop_failed "P016_CONNECTOR_STOP_CMD exited non-zero" || return 1
    fi
    if bash -c "$P016_CHECK_OFFLINE_CMD"; then
        record offline-shown PASS offline_shown "the phone showed the workspace offline state" || true
    else
        record offline-shown FAIL offline_not_shown "P016_CHECK_OFFLINE_CMD exited non-zero" || rc=1
    fi
    if ! restart; then
        record offline FAIL restart_failed "P016_CONNECTOR_START_CMD exited non-zero" || return 1
    fi
    if bash -c "$P016_CHECK_RECOVERED_CMD"; then
        record offline-recovered PASS recovered "the phone recovered after the connector returned" || true
    else
        record offline-recovered FAIL not_recovered "P016_CHECK_RECOVERED_CMD exited non-zero" || rc=1
    fi
    return "$rc"
}

# A command's output as a non-negative integer, or empty when it is not one.
count_from() {
    local out
    out="$(bash -c "$1" 2>/dev/null | tail -n 1 | tr -d '[:space:]')" || true
    case "$out" in ''|*[!0-9]*) echo "" ;; *) echo "$out" ;; esac
}

cmd_no_plaintext() {
    [ $# -eq 1 ] || usage
    local canary="$1"
    [ ${#canary} -ge 12 ] || { echo "ERROR: use a unique canary of at least 12 characters" >&2; exit 2; }
    [ -n "${P016_MACHINE_SCAN_CMD:-}" ] || {
        echo "ERROR: P016_MACHINE_SCAN_CMD is required: without the positive control an absence proves nothing" >&2
        exit 2
    }
    local machine
    machine="$(count_from "$P016_MACHINE_SCAN_CMD")"
    if [ -z "$machine" ] || [ "$machine" -eq 0 ]; then
        record no-plaintext FAIL no_positive_control "the canary was not found on the machine (count=${machine:-unreadable}), so the phone never delivered it and absence would be vacuous"
        return
    fi
    local unit="${P016_CONTROL_PLANE_UNIT:-papercusp-hosted-control-plane.service}"
    local journal_cmd="${P016_JOURNAL_CMD:-journalctl --user -u $unit --since \"${P016_SINCE:-2 hours ago}\" --no-pager}"
    local journal_out journal_hits
    if ! journal_out="$(bash -c "$journal_cmd" 2>&1)"; then
        record no-plaintext FAIL journal_unreadable "the control-plane journal read failed: $journal_cmd"
        return
    fi
    journal_hits="$(printf '%s\n' "$journal_out" | grep -cF -- "$canary" || true)"
    local extra_hits=0
    if [ -n "${P016_EXTRA_SCAN_CMD:-}" ]; then
        extra_hits="$(count_from "$P016_EXTRA_SCAN_CMD")"
        if [ -z "$extra_hits" ]; then
            record no-plaintext FAIL extra_scan_unreadable "P016_EXTRA_SCAN_CMD did not print a count"
            return
        fi
    fi
    if [ "$journal_hits" -eq 0 ] && [ "$extra_hits" -eq 0 ]; then
        record no-plaintext PASS no_plaintext "canary absent from the control plane (journal=0 extra=0) and present on the machine (count=$machine)"
    else
        record no-plaintext FAIL plaintext_seen "canary found on the control plane (journal=$journal_hits extra=$extra_hits)"
    fi
}

[ $# -ge 1 ] || usage
sub="$1"
shift
case "$sub" in
    preflight) cmd_preflight "$@" ;;
    pair-payload) cmd_pair_payload "$@" ;;
    phone) cmd_phone ;;
    offline) cmd_offline ;;
    no-plaintext) cmd_no_plaintext "$@" ;;
    classify) cmd_classify "$@" ;;
    -h|--help|help) usage ;;
    *) usage ;;
esac
