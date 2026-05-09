# FCM (Android push) setup

The Android build is now wired for Firebase Cloud Messaging — drops in a
`google-services.json` to enable. Without it, the app builds fine and
runs, just no push.

## One-time Firebase setup

1. **Create a Firebase project.** https://console.firebase.google.com
   → Add project → name it `papercusp-mobile` (or anything).
2. **Add an Android app.**
   - Package name: `com.papercuspai.operator.mobile` (must match
     `tauri.conf.json` `identifier`)
   - SHA-1 (debug): run
     ```
     keytool -keystore ~/.android/debug.keystore -storepass android \
             -keypass android -alias androiddebugkey -list -v \
       | grep "SHA1:"
     ```
3. **Download `google-services.json`** and drop it into:
   ```
   apps/operator-mobile/src-tauri/gen/android/app/google-services.json
   ```
   The Gradle plugin auto-applies when this file exists; absence is
   fine for dev (build succeeds without push).
4. **Generate an FCM service-account JSON** for the operator
   side (server-to-FCM signing). In Firebase Console → Project
   settings → Service accounts → Generate new private key. Save to
   `~/.papercusp/fcm-service-account.json` and set:
   ```
   FCM_SERVICE_ACCOUNT_PATH=/home/marsh-office/.papercusp/fcm-service-account.json
   ```
   in `apps/operator/.env.local`. The `lib/mobile-push-credentials.ts`
   minter picks this up at startup and refreshes OAuth tokens every 50
   minutes.

## Verifying

After `google-services.json` is in place:

```sh
cd apps/operator-mobile
npx tauri android dev
```

When the app launches on a real device, check `adb logcat | grep PapercuspFCM`
— you should see `FCM token: <token>`. The token is written to
`SharedPreferences("papercusp")` under `papercusp_fcm_token`. The Rust
`mobile_get_push_token` command is currently a stub on Android (needs a
JNI bridge to read the SharedPreferences key — see [JNI gap](#jni-gap)
below). Once that's wired, `ensurePushRegistered()` in `src/lib/push.ts`
posts the token to `/api/mobile/push/register` and the desktop
dispatcher can target this device.

## JNI gap

`src-tauri/src/mesh.rs` has `mobile_get_push_token` returning Err on
Android. The clean fix uses Tauri 2's mobile-plugin system:

1. Generate a plugin scaffold: `npx tauri plugin new --android push-token-bridge`
2. In the generated Kotlin plugin, expose a method that reads
   `getSharedPreferences("papercusp", MODE_PRIVATE).getString("papercusp_fcm_token", null)`
3. In Rust, replace the stub with `app.run_mobile_plugin("push-token-bridge", "getToken", ())`
4. The JS side (`src/lib/push.ts`) doesn't change.

Estimated work: ~30 min once you have a real device + adb to test
against. Today this is gated on having a phone connected — without
that, FCM token retrieval can't be verified end-to-end.

## Test push roundtrip

Once token is registered:

```sh
# Find the device id we paired
psql -U harness_admin papercusp -c \
  "SELECT device_id FROM harness_shared.mobile_devices ORDER BY paired_at DESC LIMIT 1;"

# Trigger a push (operator-side, with FCM creds set in env)
curl -X POST http://localhost:3070/api/agent-mcp/mobile-push-test \
  -H 'content-type: application/json' \
  -d '{"deviceId": "<from above>", "title": "test", "body": "hello"}'
```

Expected: phone shows banner; tap routes via `lib/push-routing.ts`'s
intervention/plan-review/smoke-fail/operator-suggestion handler.
