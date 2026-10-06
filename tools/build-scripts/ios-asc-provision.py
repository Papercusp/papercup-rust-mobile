#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Create the iPhone App Store signing material through the App Store Connect API.

iphone-public-release-2026-08-11#D-017, WI-10006953. With one App Store Connect
API key (Admin role) this registers the bundle ID, enables Push Notifications
on it, issues the Apple Distribution certificate for dist.csr and creates the
App Store provisioning profile. It writes them into the private folder that
ios-signing-secrets.sh reads (default ~/.papercusp/secrets/apple):

  reads : dist.key, dist.csr, asc/AuthKey_<KEY ID>.p8, notes.txt (Issuer ID)
  writes: dist.cer, appstore.mobileprovision

`plan` (the default) only reads the API and prints EXISTS / CREATE lines.
`apply` creates what is missing and writes the two files. Neither prints a
secret. Apple's API cannot create the App Store Connect app record; while it is
missing the output ends with WAITING_FOR and the exit code is 3 (the cert and
profile are still created by `apply`, since they do not depend on it).

Usage: ios-asc-provision.py [plan|apply]
Environment: PAPERCUP_APPLE_SECRETS_DIR, PAPERCUP_ASC_API_BASE (tests),
PAPERCUP_IOS_BUNDLE_ID.
"""
import base64
import datetime
import glob
import json
import os
import re
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

DIR = os.environ.get("PAPERCUP_APPLE_SECRETS_DIR") or os.path.expanduser("~/.papercusp/secrets/apple")
API = (os.environ.get("PAPERCUP_ASC_API_BASE") or "https://api.appstoreconnect.apple.com").rstrip("/")
BUNDLE_ID = os.environ.get("PAPERCUP_IOS_BUNDLE_ID") or "com.papercuspai.operator.mobile"
BUNDLE_NAME = "Papercup"
PROFILE_NAME = "Papercup App Store"
CERT_OUT = "dist.cer"
PROFILE_OUT = "appstore.mobileprovision"
UUID_RE = re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b")
WAITING_EXIT = 3


def die(message):
    print("ERROR: " + message, file=sys.stderr)
    sys.exit(1)


def require_private(path):
    mode = stat.S_IMODE(os.stat(path).st_mode)
    if mode & 0o077:
        die(f"{path} is readable by group or others (mode {mode:o}); chmod go-rwx it")


def openssl(*args, data=None):
    result = subprocess.run(["openssl", *args], input=data, capture_output=True, check=False)
    if result.returncode != 0:
        die(f"openssl {args[0]} failed: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout


def b64url(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def der_signature_to_raw(sig):
    """ECDSA-Sig-Value (DER SEQUENCE of two INTEGERs) -> the 64-byte r||s JWS form."""
    def length(buf, i):
        first = buf[i]
        if first < 0x80:
            return first, i + 1
        count = first & 0x7F
        return int.from_bytes(buf[i + 1:i + 1 + count], "big"), i + 1 + count

    if not sig or sig[0] != 0x30:
        die("unexpected ECDSA signature encoding from openssl")
    _, i = length(sig, 1)
    raw = b""
    for _ in range(2):
        if sig[i] != 0x02:
            die("unexpected ECDSA signature encoding from openssl")
        size, i = length(sig, i + 1)
        value = sig[i:i + size].lstrip(b"\0")
        i += size
        if len(value) > 32:
            die("the API key is not a P-256 key (App Store Connect keys are ES256)")
        raw += value.rjust(32, b"\0")
    return raw


def api_token(key_path, key_id, issuer):
    now = int(time.time())
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    # Apple rejects tokens that live longer than 20 minutes.
    payload = {"iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}
    signing_input = ".".join(
        b64url(json.dumps(part, separators=(",", ":")).encode()) for part in (header, payload)
    )
    signature = openssl("dgst", "-sha256", "-sign", key_path, data=signing_input.encode())
    return signing_input + "." + b64url(der_signature_to_raw(signature))


class Client:
    def __init__(self, token):
        self.token = token

    def call(self, method, path, body=None):
        request = urllib.request.Request(
            API + path,
            data=None if body is None else json.dumps(body).encode(),
            method=method,
            headers={
                "Authorization": "Bearer " + self.token,
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                raw = response.read()
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace")
            try:
                errors = json.loads(detail).get("errors", [])
                detail = "; ".join(
                    f"{e.get('code')}: {e.get('detail') or e.get('title')}" for e in errors
                ) or detail
            except ValueError:
                pass
            die(f"{method} {path.split('?')[0]} -> HTTP {error.code}: {detail[:600]}")
        except urllib.error.URLError as error:
            die(f"{method} {path.split('?')[0]} failed: {error.reason}")
        return json.loads(raw) if raw else {}

    def all(self, path):
        rows = []
        while path:
            page = self.call("GET", path)
            rows += page.get("data", [])
            following = (page.get("links") or {}).get("next")
            path = following[len(API):] if following and following.startswith(API) else None
        return rows


def query(path, **params):
    return path + "?" + urllib.parse.urlencode(params)


def write_private(name, content):
    path = os.path.join(DIR, name)
    with open(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "wb") as handle:
        handle.write(content)
    print(f"WROTE: {path}")


def unexpired(der):
    return subprocess.run(
        ["openssl", "x509", "-inform", "der", "-noout", "-checkend", "0"],
        input=der, capture_output=True, check=False,
    ).returncode == 0


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "plan"
    if mode not in ("plan", "apply") or len(sys.argv) > 2:
        die("usage: ios-asc-provision.py [plan|apply]")
    apply = mode == "apply"
    os.umask(0o077)

    # ------------------------------------------------------------- the folder
    if not os.path.isdir(DIR):
        die(f"secrets folder not found: {DIR}")
    require_private(DIR)
    key_file = os.path.join(DIR, "dist.key")
    csr_file = os.path.join(DIR, "dist.csr")
    for path in (key_file, csr_file):
        if not os.path.isfile(path):
            die(f"{path} not found (generate dist.key and dist.csr first, see docs/BUILD.md)")
    require_private(key_file)
    # ios-signing-secrets.sh needs exactly one .cer and one .mobileprovision.
    for pattern, ours in (("*.cer", CERT_OUT), ("*.mobileprovision", PROFILE_OUT)):
        others = [p for p in glob.glob(os.path.join(DIR, pattern)) if os.path.basename(p) != ours]
        if others:
            die(f"{', '.join(others)} is already in {DIR}; remove it so {ours} is the only {pattern}")

    waiting = []
    keys = glob.glob(os.path.join(DIR, "asc", "AuthKey_*.p8"))
    if len(keys) > 1:
        die("more than one asc/AuthKey_*.p8; keep only the Admin key")
    if not keys:
        waiting.append(f"App Store Connect API key, Admin role ({DIR}/asc/AuthKey_<KEY ID>.p8)")
    notes = os.path.join(DIR, "notes.txt")
    issuers = []
    if os.path.isfile(notes):
        with open(notes, encoding="utf-8", errors="replace") as handle:
            issuers = sorted({u.lower() for u in UUID_RE.findall(handle.read())})
    if len(issuers) > 1:
        die("notes.txt has more than one UUID; keep only the App Store Connect Issuer ID")
    if not issuers:
        waiting.append(f"App Store Connect Issuer ID ({notes})")
    if waiting:
        for item in waiting:
            print("WAITING_FOR: " + item)
        return WAITING_EXIT

    key_path = keys[0]
    key_id = os.path.basename(key_path)[len("AuthKey_"):-len(".p8")]
    api = Client(api_token(key_path, key_id, issuers[0]))

    # ---------------------------------------------------------- 1. bundle ID
    bundles = [
        b for b in api.all(query("/v1/bundleIds", **{"filter[identifier]": BUNDLE_ID, "limit": 200}))
        if b["attributes"].get("identifier") == BUNDLE_ID
    ]
    bundle = bundles[0]["id"] if bundles else None
    if bundle:
        print(f"EXISTS: bundle ID {BUNDLE_ID}")
    elif apply:
        bundle = api.call("POST", "/v1/bundleIds", {"data": {
            "type": "bundleIds",
            "attributes": {"identifier": BUNDLE_ID, "name": BUNDLE_NAME, "platform": "IOS"},
        }})["data"]["id"]
        print(f"CREATED: bundle ID {BUNDLE_ID}")
    else:
        print(f"CREATE: bundle ID {BUNDLE_ID}")

    # ------------------------------------------------- 2. Push Notifications
    capabilities = api.all(f"/v1/bundleIds/{bundle}/bundleIdCapabilities") if bundle else []
    if any(c["attributes"].get("capabilityType") == "PUSH_NOTIFICATIONS" for c in capabilities):
        print(f"EXISTS: Push Notifications on {BUNDLE_ID}")
    elif apply:
        api.call("POST", "/v1/bundleIdCapabilities", {"data": {
            "type": "bundleIdCapabilities",
            "attributes": {"capabilityType": "PUSH_NOTIFICATIONS"},
            "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle}}},
        }})
        print(f"CREATED: Push Notifications on {BUNDLE_ID}")
    else:
        print(f"CREATE: Push Notifications on {BUNDLE_ID}")

    # ------------------------------------------ 3. Apple Distribution certificate
    wanted_key = openssl("pkey", "-in", key_file, "-pubout")
    cert = None
    for candidate in api.all(query("/v1/certificates", **{"filter[certificateType]": "DISTRIBUTION", "limit": 200})):
        der = base64.b64decode(candidate["attributes"].get("certificateContent") or "")
        if der and unexpired(der) and openssl("x509", "-inform", "der", "-noout", "-pubkey", data=der) == wanted_key:
            cert = candidate
            break
    if cert:
        print("EXISTS: Apple Distribution certificate for dist.key")
    elif apply:
        with open(csr_file, encoding="ascii") as handle:
            csr = handle.read()
        cert = api.call("POST", "/v1/certificates", {"data": {
            "type": "certificates",
            "attributes": {"certificateType": "DISTRIBUTION", "csrContent": csr},
        }})["data"]
        der = base64.b64decode(cert["attributes"]["certificateContent"])
        if openssl("x509", "-inform", "der", "-noout", "-pubkey", data=der) != wanted_key:
            die("Apple issued a certificate that is not for dist.key; dist.csr and dist.key do not match")
        print("CREATED: Apple Distribution certificate for dist.csr")
    else:
        print("CREATE: Apple Distribution certificate for dist.csr")
    if cert:
        write_private(CERT_OUT, base64.b64decode(cert["attributes"]["certificateContent"]))

    # ------------------------------------------------- 4. App Store profile
    profile = None
    if bundle and cert:
        listed = api.all(query("/v1/profiles", **{
            "filter[name]": PROFILE_NAME, "filter[profileType]": "IOS_APP_STORE", "limit": 200,
        }))
        for candidate in (p for p in listed if p["attributes"].get("name") == PROFILE_NAME):
            carried = {c["id"] for c in api.all(f"/v1/profiles/{candidate['id']}/certificates")}
            if candidate["attributes"].get("profileState") == "ACTIVE" and cert["id"] in carried:
                profile = candidate
                break
            # Apple keeps profile names unique; a stale one must go before a new one can exist.
            if apply:
                api.call("DELETE", f"/v1/profiles/{candidate['id']}")
                print(f"DELETED: profile '{PROFILE_NAME}' (inactive or without this certificate)")
            else:
                print(f"REPLACE: profile '{PROFILE_NAME}' (inactive or without this certificate)")
    if profile:
        print(f"EXISTS: App Store profile '{PROFILE_NAME}'")
    elif apply:
        profile = api.call("POST", "/v1/profiles", {"data": {
            "type": "profiles",
            "attributes": {"name": PROFILE_NAME, "profileType": "IOS_APP_STORE"},
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": bundle}},
                "certificates": {"data": [{"type": "certificates", "id": cert["id"]}]},
            },
        }})["data"]
        print(f"CREATED: App Store profile '{PROFILE_NAME}'")
    else:
        print(f"CREATE: App Store profile '{PROFILE_NAME}'")
    if profile:
        content = profile["attributes"].get("profileContent")
        if not content:
            content = api.call("GET", f"/v1/profiles/{profile['id']}")["data"]["attributes"]["profileContent"]
        write_private(PROFILE_OUT, base64.b64decode(content))

    # ------------------------------------------- 5. App Store Connect app record
    apps = [
        a for a in api.all(query("/v1/apps", **{"filter[bundleId]": BUNDLE_ID, "limit": 200}))
        if a["attributes"].get("bundleId") == BUNDLE_ID
    ]
    if not apply and not (cert and profile):
        print("NEXT: run `ios-asc-provision.py apply` to create the items above")
    elif cert and profile:
        print("NEXT: bash tools/build-scripts/ios-signing-secrets.sh plan")
    if apps:
        print(f"EXISTS: App Store Connect app record '{apps[0]['attributes'].get('name')}'")
        return 0
    print(
        f"WAITING_FOR: the App Store Connect app record for {BUNDLE_ID} "
        "(App Store Connect > Apps > + > New App; Apple's API cannot create it)"
    )
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"CHECKED_AT: {stamp}")
    return WAITING_EXIT


if __name__ == "__main__":
    sys.exit(main())
