#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Tests tools/verify-byoc-cloud-relay.sh (P-016 runner) without a network, a phone or a cloud
# workspace: the response classifier, a stub relay for preflight, the pair-payload checks, the
# offline drill's always-restart rule, and the no-plaintext positive control.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="$ROOT/tools/verify-byoc-cloud-relay.sh"
WORK="$(mktemp -d)"
STUB_PID=""
cleanup() { [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT
export P016_EVIDENCE="$WORK/evidence.jsonl"
fails=0

expect() { # expect <label> <want-exit> <want-substring> -- <command...>
    local label="$1" want_rc="$2" want_out="$3"; shift 4
    local out rc=0
    out="$("$@" 2>&1)" || rc=$?
    if [ "$rc" != "$want_rc" ] || ! grep -qF -- "$want_out" <<<"$out"; then
        echo "FAIL $label: rc=$rc (want $want_rc), output: $out"; fails=$((fails + 1))
    else
        echo "ok   $label"
    fi
}

# classifier
expect "byoc refusal passes" 0 "PASS relay_live_byoc" -- "$RUNNER" classify 403 byoc_plaintext_relay_refused
expect "token refusal is not byoc" 0 "FAIL not_byoc" -- "$RUNNER" classify 401 device_token_required
expect "portal catch-all means no ingress" 0 "FAIL ingress_missing" -- "$RUNNER" classify 401 portal_auth_required
expect "plain 404 means no route" 0 "FAIL relay_route_absent" -- "$RUNNER" classify 404 -
expect "offline connector" 0 "FAIL connector_offline" -- "$RUNNER" classify 503 workspace_offline
expect "no response" 0 "FAIL unreachable" -- "$RUNNER" classify 000 -
expect "papercusp hosting is unconfirmed" 0 "PASS relay_live_unconfirmed_hosting" -- env P016_EXPECT_HOSTING=papercusp "$RUNNER" classify 401 device_token_required

# preflight against a stub relay: ws-byoc answers like a BYOC workspace, everything else 404s.
PORT_FILE="$WORK/port"
python3 - "$PORT_FILE" <<'PY' &
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/api/workspaces/ws-byoc/api/device/heartbeat":
            body, status, ctype = json.dumps({"error": "byoc_plaintext_relay_refused"}).encode(), 403, "application/json"
        else:
            body, status, ctype = b"404 Not Found", 404, "text/plain"
        self.send_response(status); self.send_header("content-type", ctype); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(s.server_address[1]))
s.serve_forever()
PY
STUB_PID=$!
for _ in $(seq 50); do [ -s "$PORT_FILE" ] && break; sleep 0.1; done
PORTAL="http://127.0.0.1:$(cat "$PORT_FILE")"
expect "preflight byoc passes" 0 "P016_CHECK preflight PASS relay_live_byoc" -- env P016_PORTAL="$PORTAL" "$RUNNER" preflight ws-byoc
expect "preflight missing route fails" 1 "P016_CHECK preflight FAIL relay_route_absent" -- env P016_PORTAL="$PORTAL" "$RUNNER" preflight ws-other
grep -q '"check": "preflight", "verdict": "PASS"' "$P016_EVIDENCE" || { echo "FAIL evidence row not written"; fails=$((fails + 1)); }

# pair payload
KEY="$(python3 -c 'import base64; print(base64.b64encode(bytes(32)).decode())')"
P="https://app.papercusp.com/api/workspaces/ws-1"
printf '{"server":"%s/","pairToken":"t","workspaceId":"w","noiseKey":"%s"}' "$P" "$KEY" >"$WORK/good.json"
printf '{"server":"http://10.128.0.5:3070","pairToken":"t","workspaceId":"w","noiseKey":"%s"}' "$KEY" >"$WORK/lan.json"
printf '{"server":"%s","pairToken":"t","workspaceId":"w"}' "$P" >"$WORK/nokey.json"
printf '{"server":"%s","pairToken":"t","workspaceId":"w","noiseKey":"AAAA"}' "$P" >"$WORK/shortkey.json"
expect "relay payload passes" 0 "PASS pair_payload_relay" -- "$RUNNER" pair-payload ws-1 "$WORK/good.json"
expect "private address fails" 1 "FAIL server_not_relay" -- "$RUNNER" pair-payload ws-1 "$WORK/lan.json"
expect "byoc needs noiseKey" 1 "FAIL noise_key_missing" -- "$RUNNER" pair-payload ws-1 "$WORK/nokey.json"
expect "noiseKey must be 32 bytes" 1 "FAIL noise_key_length" -- "$RUNNER" pair-payload ws-1 "$WORK/shortkey.json"

# offline drill: the connector is restarted exactly once, even when the offline check fails.
OFF=(env P016_CONNECTOR_STOP_CMD="echo stop >>$WORK/conn" P016_CONNECTOR_START_CMD="echo start >>$WORK/conn"
     P016_CHECK_RECOVERED_CMD=true)
expect "offline drill passes" 0 "offline-recovered PASS" -- "${OFF[@]}" P016_CHECK_OFFLINE_CMD=true "$RUNNER" offline
: >"$WORK/conn"
expect "failed offline check still restarts" 1 "offline-shown FAIL" -- "${OFF[@]}" P016_CHECK_OFFLINE_CMD=false "$RUNNER" offline
[ "$(grep -c start "$WORK/conn")" = 1 ] || { echo "FAIL connector restarted $(grep -c start "$WORK/conn") times, want 1"; fails=$((fails + 1)); }
expect "offline needs its commands" 2 "P016_CONNECTOR_STOP_CMD is required" -- "$RUNNER" offline

# no-plaintext: absence counts only with a positive control on the machine.
C="p016-canary-0123456789"
NP=(env P016_JOURNAL_CMD="printf 'relay frame sealed\n'")
expect "clean control plane passes" 0 "PASS no_plaintext" -- "${NP[@]}" P016_MACHINE_SCAN_CMD="echo 2" "$RUNNER" no-plaintext "$C"
expect "no positive control fails" 1 "FAIL no_positive_control" -- "${NP[@]}" P016_MACHINE_SCAN_CMD="echo 0" "$RUNNER" no-plaintext "$C"
expect "canary in journal fails" 1 "FAIL plaintext_seen" -- env P016_JOURNAL_CMD="echo chat $C" P016_MACHINE_SCAN_CMD="echo 1" "$RUNNER" no-plaintext "$C"
expect "canary in extra scan fails" 1 "FAIL plaintext_seen" -- "${NP[@]}" P016_MACHINE_SCAN_CMD="echo 1" P016_EXTRA_SCAN_CMD="echo 3" "$RUNNER" no-plaintext "$C"
expect "machine scan is required" 2 "P016_MACHINE_SCAN_CMD is required" -- "$RUNNER" no-plaintext "$C"

if [ "$fails" -ne 0 ]; then
    echo "verify-byoc-cloud-relay-test: $fails failed"
    exit 1
fi
echo "verify-byoc-cloud-relay-test: all passed"
