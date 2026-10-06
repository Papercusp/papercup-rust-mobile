#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ios-asc-provision.py (WI-10006953) against a stub App Store Connect API that
# verifies every ES256 token, never Apple. The produced certificate and profile
# then go through the real ios-signing-secrets.sh plan (with a fake gh), so the
# files are proven acceptable to the TestFlight workflow's own checks. The
# subject paths are overridable so a mutated COPY can be checked.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROVISION="${PAPERCUP_TEST_PROVISION_SCRIPT:-$ROOT/tools/build-scripts/ios-asc-provision.py}"
SECRETS="${PAPERCUP_TEST_SECRETS_SCRIPT:-$ROOT/tools/build-scripts/ios-signing-secrets.sh}"
SIGNING="${PAPERCUP_TEST_SIGNING_SCRIPT:-$ROOT/tools/build-scripts/ios-ci-signing.sh}"
TMP="$(mktemp -d)"
STUB_PID=""
cleanup() {
    [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

TEAM=ABCDE12345
BUNDLE=com.papercuspai.operator.mobile
KEY_ID=FIXTURE001
ISSUER=69a6de7f-1111-2222-3333-444455556666
F="$TMP/apple"
mkdir -p "$TMP/bin" "$TMP/src" "$TMP/gh-store"

fail() {
    echo "FAIL: $*" >&2
    for f in out err requests; do
        [ -f "$TMP/$f" ] && sed "s/^/  $f: /" "$TMP/$f" >&2
    done
    exit 1
}
ok() { echo "ok: $*"; }

# ------------------------------------------------------------ fixture keys
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TMP/src/dist.key" 2>/dev/null
openssl req -new -key "$TMP/src/dist.key" -subj '/emailAddress=fixture@papercusp.test/CN=Papercusp Fixture/C=US' \
    -out "$TMP/src/dist.csr" 2>/dev/null
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TMP/src/other.key" 2>/dev/null
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$TMP/src/AuthKey_$KEY_ID.p8" 2>/dev/null
openssl pkey -in "$TMP/src/AuthKey_$KEY_ID.p8" -pubout -out "$TMP/src/asc.pub" 2>/dev/null
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/src/ca.key" -out "$TMP/src/ca.pem" \
    -subj '/CN=Papercup fixture Apple CA' -days 2 >/dev/null 2>&1
# A Distribution certificate for ANOTHER key already in the account: must not be reused.
openssl req -x509 -new -key "$TMP/src/other.key" -days 2 -outform der -out "$TMP/src/foreign.der" \
    -subj "/CN=Apple Distribution: Papercusp Fixture ($TEAM)/OU=$TEAM/O=Papercusp Fixture/C=US" 2>/dev/null

# ------------------------------------------------------- stub App Store Connect
cat > "$TMP/stub.py" <<'PY'
import base64, datetime, http.server, json, os, plistlib, subprocess, sys, tempfile, urllib.parse

TMP, TEAM, BUNDLE, KEY_ID, ISSUER = sys.argv[1:6]
SRC = os.path.join(TMP, "src")
state = {
    "bundleIds": [{"id": "DECOY", "attributes": {"identifier": BUNDLE + ".widget"}}],
    "caps": {},
    "certificates": [{"id": "FOREIGN", "attributes": {
        "certificateType": "DISTRIBUTION",
        "certificateContent": base64.b64encode(open(os.path.join(SRC, "foreign.der"), "rb").read()).decode()}}],
    "profiles": [], "profile_certs": {}, "apps": [], "seq": 0,
}

def run(*args, data=None):
    return subprocess.run(args, input=data, capture_output=True, check=True).stdout

def raw_to_der(raw):
    def integer(x):
        x = x.lstrip(b"\0") or b"\0"
        if x[0] & 0x80:
            x = b"\0" + x
        return b"\x02" + bytes([len(x)]) + x
    body = integer(raw[:32]) + integer(raw[32:])
    return b"\x30" + bytes([len(body)]) + body

def unb64(part):
    return base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))

def token_ok(header):
    if not header.startswith("Bearer "):
        return "missing bearer token"
    parts = header[len("Bearer "):].split(".")
    if len(parts) != 3:
        return "malformed token"
    head, claims = json.loads(unb64(parts[0])), json.loads(unb64(parts[1]))
    if head != {"alg": "ES256", "kid": KEY_ID, "typ": "JWT"}:
        return f"bad header {head}"
    if claims.get("iss") != ISSUER or claims.get("aud") != "appstoreconnect-v1":
        return f"bad claims {claims}"
    if not 0 < claims["exp"] - claims["iat"] <= 1200:
        return "token lifetime over 20 minutes"
    sig = raw_to_der(unb64(parts[2]))
    with tempfile.NamedTemporaryFile() as handle:
        handle.write(sig); handle.flush()
        result = subprocess.run(["openssl", "dgst", "-sha256", "-verify", os.path.join(SRC, "asc.pub"),
                                 "-signature", handle.name], input=(parts[0] + "." + parts[1]).encode(),
                                capture_output=True)
    return None if result.returncode == 0 else "signature does not verify"

def next_id(prefix):
    state["seq"] += 1
    return f"{prefix}{state['seq']}"

def issue_certificate(csr_pem):
    with tempfile.TemporaryDirectory() as work:
        open(os.path.join(work, "req.csr"), "w").write(csr_pem)
        return run("openssl", "x509", "-req", "-in", os.path.join(work, "req.csr"),
                   "-CA", os.path.join(SRC, "ca.pem"), "-CAkey", os.path.join(SRC, "ca.key"),
                   "-set_serial", str(1000 + state["seq"]), "-days", "2", "-outform", "der",
                   "-subj", f"/UID={BUNDLE}/CN=Apple Distribution: Papercusp Fixture ({TEAM})/OU={TEAM}/O=Papercusp Fixture/C=US")

def build_profile(cert_ids):
    now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None, microsecond=0)
    certs = [base64.b64decode(c["attributes"]["certificateContent"])
             for c in state["certificates"] if c["id"] in cert_ids]
    plist = plistlib.dumps({
        "Name": "Papercup App Store", "UUID": "11111111-2222-3333-4444-555555555555",
        "TeamIdentifier": [TEAM], "ExpirationDate": now + datetime.timedelta(days=300),
        "DeveloperCertificates": certs,
        "Entitlements": {"application-identifier": f"{TEAM}.{BUNDLE}", "get-task-allow": False,
                         "aps-environment": "production"},
    })
    return run("openssl", "smime", "-sign", "-binary", "-nodetach", "-outform", "der",
               "-signer", os.path.join(SRC, "ca.pem"), "-inkey", os.path.join(SRC, "ca.key"), data=plist)

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, body=None):
        raw = b"" if body is None else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def handle_any(self, method):
        url = urllib.parse.urlparse(self.path)
        q = {k: v[0] for k, v in urllib.parse.parse_qs(url.query).items()}
        with open(os.path.join(TMP, "requests"), "a") as log:
            log.write(f"{method} {url.path}\n")
        if url.path == "/_stub/app":
            state["apps"].append({"id": "APP1", "attributes": {"bundleId": BUNDLE, "name": "Papercup"}})
            return self.reply(204)
        problem = token_ok(self.headers.get("Authorization", ""))
        if problem:
            return self.reply(401, {"errors": [{"code": "NOT_AUTHORIZED", "detail": problem}]})
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        p = url.path
        if method == "GET" and p == "/v1/bundleIds":
            # Apple's identifier filter is not an exact match: the decoy comes back too.
            return self.reply(200, {"data": [b for b in state["bundleIds"]
                                             if b["attributes"]["identifier"].startswith(q["filter[identifier]"])]})
        if method == "POST" and p == "/v1/bundleIds":
            row = {"id": next_id("B"), "attributes": dict(body["data"]["attributes"])}
            state["bundleIds"].append(row)
            return self.reply(201, {"data": row})
        if method == "GET" and p.startswith("/v1/bundleIds/") and p.endswith("/bundleIdCapabilities"):
            return self.reply(200, {"data": state["caps"].get(p.split("/")[3], [])})
        if method == "POST" and p == "/v1/bundleIdCapabilities":
            bid = body["data"]["relationships"]["bundleId"]["data"]["id"]
            row = {"id": next_id("C"), "attributes": dict(body["data"]["attributes"])}
            state["caps"].setdefault(bid, []).append(row)
            return self.reply(201, {"data": row})
        if method == "GET" and p == "/v1/certificates":
            return self.reply(200, {"data": [c for c in state["certificates"]
                                             if c["attributes"]["certificateType"] == q["filter[certificateType]"]]})
        if method == "POST" and p == "/v1/certificates":
            attrs = body["data"]["attributes"]
            row = {"id": next_id("X"), "attributes": {
                "certificateType": attrs["certificateType"],
                "certificateContent": base64.b64encode(issue_certificate(attrs["csrContent"])).decode()}}
            state["certificates"].append(row)
            return self.reply(201, {"data": row})
        if method == "GET" and p == "/v1/profiles":
            return self.reply(200, {"data": [r for r in state["profiles"]
                                             if r["attributes"]["name"] == q["filter[name]"]
                                             and r["attributes"]["profileType"] == q["filter[profileType]"]]})
        if method == "GET" and p.startswith("/v1/profiles/") and p.endswith("/certificates"):
            return self.reply(200, {"data": [{"id": c} for c in state["profile_certs"].get(p.split("/")[3], [])]})
        if method == "POST" and p == "/v1/profiles":
            rel = body["data"]["relationships"]
            cert_ids = [c["id"] for c in rel["certificates"]["data"]]
            row = {"id": next_id("P"), "attributes": dict(body["data"]["attributes"], profileState="ACTIVE",
                   profileContent=base64.b64encode(build_profile(cert_ids)).decode())}
            state["profiles"].append(row)
            state["profile_certs"][row["id"]] = cert_ids
            return self.reply(201, {"data": row})
        if method == "DELETE" and p.startswith("/v1/profiles/"):
            state["profiles"] = [r for r in state["profiles"] if r["id"] != p.split("/")[3]]
            return self.reply(204)
        if method == "GET" and p == "/v1/apps":
            return self.reply(200, {"data": [a for a in state["apps"]
                                             if a["attributes"]["bundleId"] == q["filter[bundleId]"]]})
        return self.reply(404, {"errors": [{"code": "NOT_FOUND", "detail": f"stub has no {method} {p}"}]})

    def do_GET(self): self.handle_any("GET")
    def do_POST(self): self.handle_any("POST")
    def do_DELETE(self): self.handle_any("DELETE")

server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
open(os.path.join(TMP, "port"), "w").write(str(server.server_address[1]))
server.serve_forever()
PY
python3 "$TMP/stub.py" "$TMP" "$TEAM" "$BUNDLE" "$KEY_ID" "$ISSUER" &
STUB_PID=$!
for _ in $(seq 1 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
[ -s "$TMP/port" ] || fail "stub API did not start"
API="http://127.0.0.1:$(cat "$TMP/port")"

# ------------------------------------------------------------------ helpers
make_folder() { # the folder after dist.key/dist.csr were generated
    rm -rf "$F"
    mkdir -p "$F/asc"
    chmod 700 "$F"
    cp "$TMP/src/dist.key" "$TMP/src/dist.csr" "$F/"
    chmod 600 "$F/dist.key"
}
add_key() {
    cp "$TMP/src/AuthKey_$KEY_ID.p8" "$F/asc/"
    printf 'App Store Connect API key %s\nIssuer ID: %s\n' "$KEY_ID" "$ISSUER" > "$F/notes.txt"
}
provision() { # <mode>; sets RC
    : > "$TMP/requests"
    set +e
    env PAPERCUP_APPLE_SECRETS_DIR="$F" PAPERCUP_ASC_API_BASE="$API" \
        python3 "$PROVISION" "$@" > "$TMP/out" 2> "$TMP/err"
    RC=$?
    set -e
}
expect_rc() { [ "$RC" -eq "$1" ] || fail "$2: exit $RC, expected $1"; }
expect_out() { grep -q -- "$1" "$TMP/out" || fail "$2: output lacks '$1'"; }
posts() { grep -c -E '^(POST|DELETE) /v1/' "$TMP/requests" || true; }

# --------------------------------------------------------------------- cases
make_folder
provision plan
expect_rc 3 "no API key"
expect_out "WAITING_FOR: App Store Connect API key" "no API key"
[ ! -s "$TMP/requests" ] || fail "contacted the API without a key"
ok "waits for the API key and Issuer ID without calling Apple"

add_key
printf 'Issuer ID: %s\nother: %s\n' "$ISSUER" 11111111-2222-3333-4444-555555555555 > "$F/notes.txt"
provision plan
expect_rc 1 "two UUIDs"
grep -q 'more than one UUID' "$TMP/err" || fail "two UUIDs: wrong refusal"
ok "refuses notes with two UUIDs"

add_key
provision plan
expect_rc 3 "plan on an empty account"
for line in "CREATE: bundle ID $BUNDLE" "CREATE: Push Notifications" "CREATE: Apple Distribution certificate" \
    "CREATE: App Store profile" "WAITING_FOR: the App Store Connect app record"; do
    expect_out "$line" "plan on an empty account"
done
[ "$(posts)" -eq 0 ] || fail "plan wrote to the API"
[ ! -e "$F/dist.cer" ] && [ ! -e "$F/appstore.mobileprovision" ] || fail "plan wrote files"
ok "plan signs a valid ES256 token, lists what it would create and changes nothing"

provision apply
expect_rc 3 "apply without an app record"
for line in "CREATED: bundle ID $BUNDLE" "CREATED: Push Notifications" "CREATED: Apple Distribution certificate" \
    "CREATED: App Store profile" "WAITING_FOR: the App Store Connect app record"; do
    expect_out "$line" "apply"
done
[ "$(stat -c %a "$F/dist.cer")" = 600 ] && [ "$(stat -c %a "$F/appstore.mobileprovision")" = 600 ] \
    || fail "apply wrote files readable by others"
openssl x509 -inform der -in "$F/dist.cer" -noout -pubkey | cmp -s - <(openssl pkey -in "$F/dist.key" -pubout) \
    || fail "dist.cer is not for dist.key (reused the foreign certificate?)"
ok "apply creates bundle ID (exact match, not the decoy), push, certificate for dist.key and profile"

PATH_FAKE_GH="$TMP/bin/gh"
cat > "$PATH_FAKE_GH" <<'GH'
#!/usr/bin/env bash
echo "fake gh: $*" >&2; exit 2
GH
chmod +x "$PATH_FAKE_GH"
set +e
env PATH="$TMP/bin:$PATH" PAPERCUP_APPLE_SECRETS_DIR="$F" PAPERCUP_GH_REPO=Fixture/repo \
    PAPERCUP_SIGNING_SCRIPT="$SIGNING" bash "$SECRETS" plan > "$TMP/out" 2> "$TMP/err"
RC=$?
set -e
expect_rc 0 "ios-signing-secrets.sh plan on the provisioned folder"
grep -q 'APPLE_TEAM_ID' "$TMP/out" || fail "secrets plan did not list APPLE_TEAM_ID"
ok "the produced certificate and profile pass ios-signing-secrets.sh plan (team $TEAM from the certificate)"

curl -fsS -X POST "$API/_stub/app" >/dev/null
provision apply
expect_rc 0 "second apply with an app record"
for line in "EXISTS: bundle ID" "EXISTS: Push Notifications" "EXISTS: Apple Distribution certificate" \
    "EXISTS: App Store profile" "EXISTS: App Store Connect app record"; do
    expect_out "$line" "second apply"
done
[ "$(posts)" -eq 0 ] || fail "second apply wrote to the API"
ok "re-running apply is idempotent and exits 0 once the app record exists"

cp "$F/dist.cer" "$F/other.cer"
provision plan
expect_rc 1 "second .cer"
grep -q 'other.cer is already in' "$TMP/err" || fail "second .cer: wrong refusal"
rm -f "$F/other.cer"
ok "refuses when another .cer would make ios-signing-secrets.sh ambiguous"

echo "PASS: ios-asc-provision"
