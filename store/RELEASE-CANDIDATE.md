# Android release candidate

Last inspected: 2026-08-11 16:38 EDT

This record identifies the latest locally verified candidate. Re-run the release
workflow before upload; a successful run replaces the hashes below so an older
artifact cannot be mistaken for the current candidate.

## Identity

| Field | Value |
|---|---|
| Application ID | `com.papercuspai.operator.mobile` |
| Version | `0.1.0` (`versionCode` 1) |
| Minimum / target SDK | 24 / 36 |
| APK | `android/app/build/outputs/apk/release/app-release.apk` |
| APK size | 91,804,686 bytes |
| APK SHA-256 | `cf3fdafcfe0d68d4637754b38ebbf5911761a2d3bd4cbbb349927caa2712b0e3` |
| AAB | `android/app/build/outputs/bundle/release/app-release.aab` |
| AAB size | 60,419,891 bytes |
| AAB SHA-256 | `a3b74baca473825fa55921f1fb5410ff2f4b438af23865763494b67aff80cb34` |
| Upload certificate SHA-256 | `efeb65c4e03a7eb6a1c445ea6d0361e95edf1e7509fc25cb4072d3f202912b93` |
| Upload certificate subject | `CN=Papercup, OU=Mobile, O=Papercusp, C=US` |

## Verification

- `build-android.sh release` passed after rebuilding all four Rust targets and
  checking 54 UniFFI checksum symbols in each ABI library.
- APK and AAB contain exactly `arm64-v8a`, `armeabi-v7a`, `x86`, and `x86_64`;
  obsolete JNA `armeabi` and MIPS payloads are excluded.
- APK Signature Scheme v2 verification passed with one signer; `jarsigner`
  verified the AAB upload signature.
- All 14 packaged 64-bit shared libraries have ELF `LOAD` alignment of at least
  16 KB. `zipalign -c -P 16 -v 4` passed for the APK, and bundletool reports
  `PAGE_ALIGNMENT_16K` for the AAB.
- The merged release manifest targets API 36 and sets
  `android:usesCleartextTraffic="false"`.

The Google Play Console remains authoritative for whether version code 1 and
this upload certificate match any pre-existing app record.
