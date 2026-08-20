#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Regression test for inherited analytics/advertising permissions in the
# release manifest. The check builds the real release manifest so dependency
# changes cannot silently reintroduce the public Data Safety issue.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_MANIFEST="$ROOT/android/app/src/main/AndroidManifest.xml"
MERGED_MANIFEST="$ROOT/android/app/build/intermediates/merged_manifest/release/processReleaseMainManifest/AndroidManifest.xml"

node - "$SOURCE_MANIFEST" <<'NODE'
const fs = require('node:fs');
const file = process.argv[2];
const xml = fs.readFileSync(file, 'utf8');
const permissions = [
  'com.google.android.gms.permission.AD_ID',
  'android.permission.ACCESS_ADSERVICES_AD_ID',
  'android.permission.ACCESS_ADSERVICES_ATTRIBUTION',
  'com.google.android.finsky.permission.BIND_GET_INSTALL_REFERRER_SERVICE',
];
const tags = [...xml.matchAll(/<uses-permission\b[^>]*>/g)].map((match) => match[0]);
if (!xml.includes('xmlns:tools="http://schemas.android.com/tools"')) {
  throw new Error('source manifest is missing the tools namespace');
}
for (const permission of permissions) {
  const override = tags.some((tag) =>
    tag.includes(`android:name="${permission}"`) && tag.includes('tools:node="remove"'),
  );
  if (!override) throw new Error(`missing source removal override for ${permission}`);
}
NODE

(cd "$ROOT/android" && ./gradlew :app:processReleaseMainManifest --no-daemon --quiet)

node - "$MERGED_MANIFEST" <<'NODE'
const fs = require('node:fs');
const file = process.argv[2];
const xml = fs.readFileSync(file, 'utf8');
const permissions = [
  'com.google.android.gms.permission.AD_ID',
  'android.permission.ACCESS_ADSERVICES_AD_ID',
  'android.permission.ACCESS_ADSERVICES_ATTRIBUTION',
  'com.google.android.finsky.permission.BIND_GET_INSTALL_REFERRER_SERVICE',
];
const tags = [...xml.matchAll(/<uses-permission\b[^>]*>/g)].map((match) => match[0]);
for (const permission of permissions) {
  if (tags.some((tag) => tag.includes(`android:name="${permission}"`))) {
    throw new Error(`merged release manifest still declares ${permission}`);
  }
}
NODE

echo "✓ Android release manifest excludes inherited advertising, attribution, and install-referrer permissions"
