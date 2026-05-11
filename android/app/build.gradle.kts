// SPDX-License-Identifier: GPL-3.0-or-later
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
}

android {
    namespace = "com.papercuspai.operator.mobile"
    compileSdk = 35

    lint {
        lintConfig = file("lint.xml")
        abortOnError = true
        // Bring all the messy upstream warnings into the report so we
        // can pick at them over time, but don't break the build for
        // them — only errors do. (lint.xml suppresses the four NewApi
        // false-positives in generated/themes code.)
        warningsAsErrors = false
        checkAllWarnings = false
    }

    defaultConfig {
        applicationId = "com.papercuspai.operator.mobile"
        minSdk = 24
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
        // Phase 10g: Picovoice AccessKey. Empty when nobody's configured
        // it locally — WakeWordEngine treats that as "wake word disabled".
        // Set via android/local.properties:
        //   PICOVOICE_ACCESS_KEY=<key from picovoice console>
        val key = providers
            .gradleProperty("PICOVOICE_ACCESS_KEY")
            .getOrElse(System.getenv("PICOVOICE_ACCESS_KEY") ?: "")
        buildConfigField("String", "PICOVOICE_ACCESS_KEY", "\"$key\"")
    }
    buildFeatures {
        buildConfig = true
        compose = true
    }

    buildTypes {
        getByName("debug") {
            isMinifyEnabled = false
        }
        getByName("release") {
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    sourceSets["main"].kotlin {
        srcDirs("src/main/kotlin")
    }
    // libpapercup.so was placed in src/main/jniLibs by `cargo ndk` in the
    // build script; nothing extra to declare.
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.10.01")
    implementation(composeBom)
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-core")
    // Phase 9: Mic icon for the voice FAB.
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.core:core-ktx:1.15.0")

    // UniFFI's generated Kotlin needs JNA at runtime.
    implementation("net.java.dev.jna:jna:5.14.0@aar")

    // Coroutines — UniFFI's generated `suspend` fns use them.
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")

    // Phase 2: pair flow.
    // Keystore-backed credential storage.
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    // CameraX + ML Kit barcode scanner for QR ingestion.
    implementation("androidx.camera:camera-core:1.4.0")
    implementation("androidx.camera:camera-camera2:1.4.0")
    implementation("androidx.camera:camera-lifecycle:1.4.0")
    implementation("androidx.camera:camera-view:1.4.0")
    implementation("androidx.camera:camera-mlkit-vision:1.4.0")
    implementation("com.google.mlkit:barcode-scanning:17.3.0")
    // Compose ↔ Lifecycle helpers used in the pair screen.
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")

    // Phase 6b.2: WireGuard tunnel binding (zx2c4 official Android lib).
    implementation("com.wireguard.android:tunnel:1.0.20230706")

    // Phase 10g: Picovoice Porcupine for "hey papercup" wake word.
    // Engine is dormant unless PICOVOICE_ACCESS_KEY is set in
    // android/local.properties (or BuildConfig.PICOVOICE_ACCESS_KEY at
    // build time); WakeWordEngine.kt early-returns otherwise.
    implementation("ai.picovoice:porcupine-android:3.0.1")

    // Phase 11: OkHttp + okhttp-sse for the RunLog SSE tail of
    // /api/harness/{slug}/log/stream.
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.squareup.okhttp3:okhttp-sse:4.12.0")

    // Phase 8: BiometricPrompt for high-risk action gating.
    implementation("androidx.biometric:biometric:1.2.0-alpha05")
    implementation("androidx.fragment:fragment-ktx:1.8.5")

    // Phase 5a + Phase 10: Firebase BoM (FCM + Crashlytics).
    implementation(platform("com.google.firebase:firebase-bom:33.6.0"))
    implementation("com.google.firebase:firebase-messaging-ktx")
    implementation("com.google.firebase:firebase-crashlytics-ktx")
    implementation("com.google.firebase:firebase-analytics-ktx")
    // Tasks → coroutines bridge for awaiting FirebaseMessaging.getToken().
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-play-services:1.9.0")

    debugImplementation(composeBom)
    debugImplementation("androidx.compose.ui:ui-tooling")
}
