// SPDX-License-Identifier: GPL-3.0-or-later
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("com.google.gms.google-services")
}

android {
    namespace = "com.papercuspai.operator.mobile"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.papercuspai.operator.mobile"
        minSdk = 24
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
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
    buildFeatures {
        compose = true
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

    // Phase 5a: Firebase Cloud Messaging for push notifications.
    implementation(platform("com.google.firebase:firebase-bom:33.6.0"))
    implementation("com.google.firebase:firebase-messaging-ktx")
    // Tasks → coroutines bridge for awaiting FirebaseMessaging.getToken().
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-play-services:1.9.0")

    debugImplementation(composeBom)
    debugImplementation("androidx.compose.ui:ui-tooling")
}
