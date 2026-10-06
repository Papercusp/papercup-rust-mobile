# Android release candidate

This file records the **durable** facts about the Android release candidate —
the ones that do not change from build to build. It deliberately carries **no
artifact hashes, sizes, versions, or build timestamps.**

## Where the candidate identity actually lives

A release build writes the authoritative provenance manifest and a generated,
human-readable record into the (gitignored) build-output tree:

| Artifact | Path |
|---|---|
| Provenance manifest (authoritative) | `android/app/build/outputs/papercusp-release-provenance.json` |
| Generated candidate record | `android/app/build/outputs/RELEASE-CANDIDATE.md` |

```sh
tools/build-scripts/android-release-provenance.sh verify <version>   # check artifacts
tools/build-scripts/android-release-provenance.sh path               # manifest path
tools/build-scripts/android-release-provenance.sh record             # record path
```

The uploader trusts the JSON manifest. Nothing should read a per-build hash
from this tracked file.

## Why this file carries no hashes

`android-release-provenance.sh` binds provenance to a **clean tree at a known
HEAD**: `write` and `verify` both refuse to run against a dirty checkout, and
`verify` requires `sourceCommit` to equal the current HEAD.

A tracked file that is refreshed after each build cannot coexist with that
rule. Refreshing it dirties the tree, so `verify` fails at the clean-source
assertion; committing the refresh instead moves HEAD, so `verify` fails on
`sourceCommit` mismatch. Either way the evidence surface invalidates the very
provenance it was meant to evidence, and the release cannot be verified.

So the per-build record is **generated into untracked build output**, where
rewriting it is free. Do not reintroduce artifact hash, size, version, or
build-timestamp rows here — `tools/tests/android-release-provenance-test.sh`
fails if they come back.

## Durable identity

| Field | Value |
|---|---|
| Application ID | `com.papercuspai.operator.mobile` |
| Minimum / target SDK | 24 / 36 |
| Upload certificate subject | `CN=Papercup, OU=Mobile, O=Papercusp, C=US` |
| Upload certificate fingerprint | `efeb65c4e03a7eb6a1c445ea6d0361e95edf1e7509fc25cb4072d3f202912b93` |

The signing identity above describes the keystore, not any single build, so it
is stable across releases and cannot create the invalidation loop described
above.

## Standing release checks

`build-android.sh release` must pass all of the following before a candidate is
considered uploadable:

- **Publication gate:** `tools/run-android-checks.sh host` and
  `tools/run-android-checks.sh connected` have both passed on the same clean
  `HEAD`. The release refuses to build without both pass records, and the
  provenance manifest embeds them as `checks`, so `verify` fails if either is
  missing, failed or bound to another commit. See "Release publication gate" in
  `docs/BUILD.md`.
- All four Rust targets rebuild, and each ABI library exports the expected
  UniFFI checksum symbols.
- The APK and AAB contain exactly `arm64-v8a`, `armeabi-v7a`, `x86`, and
  `x86_64`; obsolete JNA `armeabi` and MIPS payloads are excluded.
- APK Signature Scheme v2 verification passes with one signer, and `jarsigner`
  verifies the AAB upload signature.
- Every packaged 64-bit shared library has ELF `LOAD` alignment of at least
  16 KB; `zipalign -c -P 16 -v 4` passes for the APK and bundletool reports
  `PAGE_ALIGNMENT_16K` for the AAB.
- The merged release manifest targets API 36 and sets
  `android:usesCleartextTraffic="false"`.

The Google Play Console remains authoritative for whether a given version code
and upload certificate match any pre-existing app record.
