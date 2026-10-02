#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Verify the actual release manifest, including collection defaults, HTTPS
# and the declared microphone service. Rejecting controls run in the same CI
# check so a broken validator cannot silently certify a privacy declaration.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_MANIFEST="$ROOT/android/app/src/main/AndroidManifest.xml"
MERGED_MANIFEST="$ROOT/android/app/build/intermediates/merged_manifest/release/processReleaseMainManifest/AndroidManifest.xml"

mode="${1:-release}"
case "$mode" in
    release) (cd "$ROOT/android" && ./gradlew :app:processReleaseMainManifest --no-daemon --quiet) ;;
    --self-test) ;;
    *) echo 'usage: android-privacy-permissions-test.sh [--self-test]' >&2; exit 2 ;;
esac

python3 - "$SOURCE_MANIFEST" "$MERGED_MANIFEST" "$mode" <<'PY'
import copy
import sys
import xml.etree.ElementTree as ET

A = '{http://schemas.android.com/apk/res/android}'
T = '{http://schemas.android.com/tools}'
BANNED = (
    'com.google.android.gms.permission.AD_ID',
    'android.permission.ACCESS_ADSERVICES_AD_ID',
    'android.permission.ACCESS_ADSERVICES_ATTRIBUTION',
    'com.google.android.finsky.permission.BIND_GET_INSTALL_REFERRER_SERVICE',
)
COLLECTION = (
    'firebase_analytics_collection_enabled',
    'google_analytics_adid_collection_enabled',
    'google_analytics_ssaid_collection_enabled',
)
MIC_PERMISSIONS = (
    'android.permission.RECORD_AUDIO',
    'android.permission.FOREGROUND_SERVICE',
    'android.permission.FOREGROUND_SERVICE_MICROPHONE',
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_merged(root):
    require(root.tag == 'manifest', 'expected manifest root')
    permissions = {p.get(A + 'name') for p in root.findall('uses-permission')}
    require(not permissions.intersection(BANNED), 'inherited advertising permission')
    apps = root.findall('application')
    require(len(apps) == 1, 'expected one application')
    app = apps[0]
    require(app.get(A + 'usesCleartextTraffic') == 'false', 'release cleartext must be false')
    for name in COLLECTION:
        rows = [r for r in app.findall('meta-data') if r.get(A + 'name') == name]
        require(len(rows) == 1 and rows[0].get(A + 'value') == 'false',
                'collection must be explicitly disabled: ' + name)
    services = [s for s in app.findall('service')
                if s.get(A + 'name') in ('.WakeWordService',
                    'com.papercuspai.operator.mobile.WakeWordService')]
    require(len(services) == 1, 'expected declared wake-word service')
    require('microphone' in services[0].get(A + 'foregroundServiceType', '').split('|'),
            'wake-word service must declare microphone type')
    require(set(MIC_PERMISSIONS).issubset(permissions), 'missing microphone service permission')


# A valid independent fixture plus one changed precondition per rejecting case.
# These controls test the validator rather than claiming candidate behavior.
fixture = ET.fromstring('''<manifest xmlns:android="http://schemas.android.com/apk/res/android">
  <application android:usesCleartextTraffic="false">
    <service android:name=".WakeWordService" android:foregroundServiceType="microphone"/>
  </application>
</manifest>''')
for permission in MIC_PERMISSIONS:
    ET.SubElement(fixture, 'uses-permission', {A + 'name': permission})
for name in COLLECTION:
    ET.SubElement(fixture.find('application'), 'meta-data', {A + 'name': name, A + 'value': 'false'})
validate_merged(fixture)
rejected = 0


def reject(mutant, reason):
    global rejected
    try:
        validate_merged(mutant)
    except ValueError as error:
        require(reason in str(error), 'control rejected for the wrong cause: ' + str(error))
        rejected += 1
    else:
        raise AssertionError('privacy validator accepted ' + reason)


for permission in BANNED:
    mutant = copy.deepcopy(fixture)
    ET.SubElement(mutant, 'uses-permission', {A + 'name': permission})
    reject(mutant, 'inherited advertising permission')
for name in COLLECTION:
    for mutation in ('enabled', 'missing', 'duplicate'):
        mutant = copy.deepcopy(fixture)
        app = mutant.find('application')
        row = next(r for r in app.findall('meta-data') if r.get(A + 'name') == name)
        if mutation == 'enabled':
            row.set(A + 'value', 'true')
        elif mutation == 'missing':
            app.remove(row)
        else:
            app.append(copy.deepcopy(row))
        reject(mutant, 'collection must be explicitly disabled: ' + name)
for value in ('true', None):
    mutant = copy.deepcopy(fixture)
    app = mutant.find('application')
    if value is None:
        del app.attrib[A + 'usesCleartextTraffic']
    else:
        app.set(A + 'usesCleartextTraffic', value)
    reject(mutant, 'release cleartext must be false')
mutant = copy.deepcopy(fixture)
mutant.find('application/service').set(A + 'foregroundServiceType', 'dataSync')
reject(mutant, 'wake-word service must declare microphone type')
for permission in MIC_PERMISSIONS:
    mutant = copy.deepcopy(fixture)
    mutant.remove(next(p for p in mutant.findall('uses-permission') if p.get(A + 'name') == permission))
    reject(mutant, 'missing microphone service permission')
mutant = copy.deepcopy(fixture)
mutant.find('application').remove(mutant.find('application/service'))
reject(mutant, 'expected declared wake-word service')
print(f'Android privacy validator: valid control passed; {rejected} invalid manifests rejected')

source = ET.parse(sys.argv[1]).getroot()
for permission in BANNED:
    overrides = [p for p in source.findall('uses-permission')
                 if p.get(A + 'name') == permission and p.get(T + 'node') == 'remove']
    require(len(overrides) == 1, 'missing source removal override for ' + permission)
if sys.argv[3] != '--self-test':
    validate_merged(ET.parse(sys.argv[2]).getroot())
    print('Android merged release manifest: advertising removals, disabled collection, HTTPS and microphone declarations passed')
PY
