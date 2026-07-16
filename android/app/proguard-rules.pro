# Release R8/ProGuard rules for the Papercup Android app (WI-4982).
#
# build.gradle.kts enables release minification and references this file.
# The app's core is Rust exposed through UniFFI-generated Kotlin bindings
# (package uniffi.papercup) that talk to the native library via JNA.
# JNA and the generated bindings resolve symbols and map types by
# REFLECTION and by NAME, so R8 renaming/stripping either of them breaks
# every native call at runtime. Keep both wholesale — they are small
# relative to the app and correctness beats the few KB saved.

# --- UniFFI generated bindings (uniffi.papercup) --------------------------
# Generated Kotlin binds native functions by name and passes callback
# interfaces across the FFI boundary; nothing here is safe to rename.
-keep class uniffi.** { *; }

# --- JNA (net.java.dev.jna) ------------------------------------------------
# JNA maps Java interfaces/structures to native symbols reflectively.
-keep class com.sun.jna.** { *; }
-keepclassmembers class * extends com.sun.jna.Structure { *; }
-keep class * implements com.sun.jna.Library { *; }
-keep class * implements com.sun.jna.Callback { *; }
# JNA references AWT types that don't exist on Android.
-dontwarn java.awt.*
-dontwarn com.sun.jna.platform.**

# --- Native methods everywhere --------------------------------------------
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}

# --- Picovoice Porcupine wake word (JNI callbacks by name) -----------------
-keep class ai.picovoice.** { *; }
-dontwarn ai.picovoice.**

# --- ElevenLabs Conversational AI SDK + LiveKit/WebRTC ---------------------
# LiveKit rides on libwebrtc JNI; org.webrtc classes are looked up from
# native code by name. The SDKs ship partial consumer rules — these keeps
# are the documented belt-and-braces set for release builds.
-keep class org.webrtc.** { *; }
-dontwarn org.webrtc.**
-keep class livekit.** { *; }
-keep class io.livekit.** { *; }
-dontwarn io.livekit.**
-keep class io.elevenlabs.** { *; }
-dontwarn io.elevenlabs.**

# --- OkHttp / Okio (harmless dontwarns; consumer rules cover the rest) -----
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn javax.annotation.**

# --- Crashlytics: keep readable stack traces -------------------------------
-keepattributes SourceFile,LineNumberTable
-keep public class * extends java.lang.Exception

# --- ML Kit barcode scanner + CameraX (QR pairing flow — release-critical) --
# PairScreen.kt calls BarcodeScanning.getClient(BarcodeScannerOptions.Builder()).
# R8 inlines/renames the factory + Builder aggressively (they showed as
# R8$$REMOVED$$CLASS in the release mapping); belt-and-braces keep the whole
# ML Kit + play-services-mlkit surface so the QR scanner can never be
# reflectively broken on a fresh-install pairing. ML Kit loads model
# providers and internal impls by name.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_** { *; }
-keep class com.google.android.gms.vision.** { *; }
-dontwarn com.google.mlkit.**
# CameraX MlKitAnalyzer bridge.
-keep class androidx.camera.mlkit.vision.** { *; }
