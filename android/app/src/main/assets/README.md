# Wake-word keyword files

Drop `hey-papercup.ppn` here when Picovoice ships the custom keyword
file. The Android `WakeWordEngine` looks for it at runtime via:

```kotlin
context.assets.open("hey-papercup.ppn")
```

If the file is absent the engine falls back to the built-in `JARVIS`
keyword (functional but off-brand). Activation also requires:

1. `PICOVOICE_ACCESS_KEY=<key>` in `android/local.properties`
2. `RECORD_AUDIO` permission granted
3. APK rebuild (BuildConfig field is baked in at compile time)

The companion iOS path is `ios/Papercup/Resources/wake-words/hey-papercup.ppn`
plus the SwiftPM Porcupine package uncomment in `project.yml`.
