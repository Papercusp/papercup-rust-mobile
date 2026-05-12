<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Wake-word activation playbook

Once Picovoice ships the AccessKey + (optional) custom `hey-papercup.ppn`
keyword file, these are the steps to flip wake-word from dormant to live
on each platform.

The code is already scaffolded — these steps are **drops + rebuilds**,
no code changes.

## What you'll receive from Picovoice

| Artifact | Purpose | Required |
|---|---|---|
| `AccessKey` (string, ~120 chars) | Authenticates the SDK at runtime | **Yes** |
| `hey-papercup.ppn` (binary, ~3-5 KB) | Custom keyword model for "hey papercup" | Optional (falls back to "Jarvis") |
| `hey-papercup_<lang>.ppn` per locale | Localized keyword models | Optional |

The AccessKey is per-organization and works for both Android + iOS. The
`.ppn` is platform-specific — Picovoice will give you one for Android
and one for iOS (they're trained against different acoustic models).

## Android activation

```bash
# 1. AccessKey
cat >> android/local.properties <<EOF
PICOVOICE_ACCESS_KEY=<paste-key-here>
EOF

# 2. (Optional) custom keyword file
cp ~/Downloads/hey-papercup_android.ppn \
  android/app/src/main/assets/hey-papercup.ppn

# 3. Rebuild + install
make build-android      # or just `./gradlew :app:assembleDebug`
```

Verify in logcat after launch:
```
PapercupVoice  I  wake word: using custom hey-papercup.ppn from assets
PapercupVoice  I  wake word listening
```

(If you skipped step 2, you'll see `falling back to JARVIS` — say "Hey
Jarvis" to test until the custom .ppn lands.)

## iOS activation

```bash
# 1. Add the SwiftPM dep — uncomment the Porcupine block in
#    ios/project.yml, then regenerate the Xcode project:
xcodegen --spec ios/project.yml

# 2. AccessKey in Info.plist
/usr/libexec/PlistBuddy -c "Add :PICOVOICE_ACCESS_KEY string <key>" \
  ios/Papercup/Info.plist

# 3. (Optional) custom keyword file
mkdir -p ios/Papercup/Resources/wake-words
cp ~/Downloads/hey-papercup_ios.ppn \
  ios/Papercup/Resources/wake-words/hey-papercup.ppn

# 4. Build + install
make build-ios
```

Verify in Xcode console:
```
[WakeWord] wake word listening
```

## Switching to openWakeWord (Picovoice-free fallback)

If Picovoice licensing terms become unacceptable, openWakeWord is the
escape hatch.

```bash
# Android only (iOS path is Porcupine-only for now)
echo "PAPERCUP_USE_OWW=true" >> android/gradle.properties
make build-android
```

Verify the engine is selected:
```
WakeWord  I  selected engine: openWakeWord (PAPERCUP_USE_OWW=true)
```

Note: openWakeWord requires a TFLite model file in
`android/app/src/main/assets/oww/hey-papercup.tflite`. The
`WakeWordEngine.kt` falls back to inert (no detection) if missing.

## What the SDK does behind the scenes

When wake-word activates:

1. App launches → `MainActivity.onCreate` → DisposableEffect at the
   AppRoot composable kicks in
2. `WakeWordEngine.isConfigured()` checks ACCESS_KEY + RECORD_AUDIO grant
3. If both green → `WakeWordService.start(context)` spawns a
   foreground service of type `microphone`
4. Service holds an FGS notification "Wake word listening"
5. Service runs `PorcupineManager` against the mic stream in a loop
6. On detection → broadcasts `WakeWordService.ACTION_WAKE`
7. Receiver in MainActivity calls `voice.start()` → full EL session

The path is **completely separate from the user-tap voice path** — both
can be active. When voice is mid-session, the FGS-microphone service
throttles itself (see `LaunchedEffect(voiceState)` in MainActivity)
so the two don't fight over the mic.

## Test matrix

Already covered by `docs/VOICE_TEST_MATRIX.md` §G — execute those 7
rows after activation.

## Cost

Picovoice Porcupine is free for non-commercial use and runs entirely on-
device (no cloud calls). For commercial product use the developer plan
is $0/month + a per-device royalty negotiated with Picovoice.

openWakeWord is Apache-2.0 and free for any use, but model quality is
materially worse on non-quiet acoustic environments.
