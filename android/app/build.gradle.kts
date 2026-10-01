// SPDX-License-Identifier: GPL-3.0-or-later
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
}

val generateUniFfiKotlin by
    tasks.registering(Exec::class) {
        val repositoryRoot =
            rootProject.layout.projectDirectory
                .dir("..")
                .asFile
        workingDir(repositoryRoot)
        commandLine("make", "bindings-kotlin")
        inputs.file(repositoryRoot.resolve("crates/papercup-bindings/src/papercup.udl"))
        inputs.file(repositoryRoot.resolve("crates/papercup-bindings/uniffi.toml"))
        inputs.file(repositoryRoot.resolve("Cargo.lock"))
        outputs.file(repositoryRoot.resolve("android/app/src/main/kotlin/uniffi/papercup/papercup.kt"))
    }

private val DEFAULT_VERSION_NAME = "0.1.0"
private val VERSION_CODE_MINOR_MULTIPLIER = 100L
private val VERSION_CODE_MAJOR_MULTIPLIER = 10_000L
private val MAX_ANDROID_VERSION_CODE = 2_100_000_000L

fun releaseSigningInput(name: String): String? =
    providers.gradleProperty(name).orNull?.takeIf { it.isNotBlank() }
        ?: System.getenv(name)?.takeIf { it.isNotBlank() }

// Resolve once so preflight validates exactly what Android signing consumes.
val releaseKeystorePath = releaseSigningInput("PAPERCUP_RELEASE_KEYSTORE")
val releaseStorePassword = releaseSigningInput("PAPERCUP_RELEASE_KEYSTORE_PASSWORD")
val releaseKeyAlias = releaseSigningInput("PAPERCUP_RELEASE_KEY_ALIAS")
val releaseKeyPassword = releaseSigningInput("PAPERCUP_RELEASE_KEY_PASSWORD") ?: releaseStorePassword

private fun androidVersionCode(versionName: String): Int {
    // Prerelease/build metadata changes the display name, not the upgrade
    // ordering. Keep the numeric MAJOR.MINOR.PATCH portion monotonic and
    // leave room for two digits of minor/patch growth per major release.
    val baseVersion = versionName.substringBefore('-').substringBefore('+')
    val components = baseVersion.split('.')
    require(
        components.size == 3 && components.all { component ->
            component.isNotEmpty() && component.all { character -> character in '0'..'9' }
        },
    ) {
        "PAPERCUP_RELEASE_VERSION must be MAJOR.MINOR.PATCH (got '$versionName')"
    }

    val major = components[0].toLongOrNull()
    val minor = components[1].toLongOrNull()
    val patch = components[2].toLongOrNull()
    require(major != null && minor != null && patch != null) {
        "PAPERCUP_RELEASE_VERSION components are too large (got '$versionName')"
    }

    val versionCode =
        major * VERSION_CODE_MAJOR_MULTIPLIER +
            minor * VERSION_CODE_MINOR_MULTIPLIER +
            patch
    require(versionCode in 1..MAX_ANDROID_VERSION_CODE) {
        "derived Android versionCode must be between 1 and $MAX_ANDROID_VERSION_CODE (got $versionCode)"
    }
    return versionCode.toInt()
}

android {
    namespace = "com.papercuspai.operator.mobile"
    compileSdk = 36

    lint {
        lintConfig = file("lint.xml")
        abortOnError = true
        // WI-5033: WI-4983's NullSafeMutableLiveData disable is lifted now
        // that lifecycle-runtime-compose is >= 2.9 (fixed detector) —
        // :app:lintVitalAnalyzeRelease verified green with the check active.
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
        targetSdk = 36
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        val releaseVersion =
            System.getenv("PAPERCUP_RELEASE_VERSION")?.takeIf { it.isNotBlank() } ?: DEFAULT_VERSION_NAME
        versionCode = androidVersionCode(releaseVersion)
        // A desktop release cut passes PAPERCUP_RELEASE_VERSION (release-local.sh sets it
        // on the Android leg; tools/build-scripts/build-android.sh REQUIRES it for a
        // release build). tools/build-scripts/android-release-provenance.sh then asserts
        // the packaged APK's versionName equals that requested version — an assertion that
        // could never hold while this value was hardcoded, so every cut's Android leg died
        // AFTER a successful build ("APK versionName is 0.1.0, but requested release
        // version is 0.0.17"), and join_leg's fatal join took the whole cut down with it.
        // Reading the env here is the missing half of that already-built plumbing; ordinary
        // dev/debug builds leave it unset and keep the repo's own 0.1.0.
        versionName = releaseVersion
        // JNA's AAR still carries obsolete armeabi/MIPS binaries. Keep the
        // published artifact to Android's four supported app ABIs; otherwise
        // those legacy payloads leak into both the APK and AAB.
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86", "x86_64")
        }
        // Release builds never send bearer credentials or user content over
        // cleartext. Debug keeps the emulator's explicit local endpoint.
        manifestPlaceholders["usesCleartextTraffic"] = "false"
        // Phase 10g: Picovoice AccessKey. Empty when nobody's configured
        // it locally — WakeWordEngine treats that as "wake word disabled".
        // Set via android/local.properties:
        //   PICOVOICE_ACCESS_KEY=<key from picovoice console>
        val key = providers
            .gradleProperty("PICOVOICE_ACCESS_KEY")
            .getOrElse(System.getenv("PICOVOICE_ACCESS_KEY") ?: "")
        buildConfigField("String", "PICOVOICE_ACCESS_KEY", "\"$key\"")

        // openWakeWord fallback. When PAPERCUP_USE_OWW=true the build
        // uses the local-ML wake-word path (TFLite ONNX model bundled
        // in assets) instead of Picovoice. Useful when the Picovoice
        // AccessKey is unavailable. Off by default until the OWW model
        // is bundled — see WakeWordEngine.kt and docs/VOICE_V1_PLAN.md.
        val useOww = providers
            .gradleProperty("PAPERCUP_USE_OWW")
            .getOrElse(System.getenv("PAPERCUP_USE_OWW") ?: "false")
            .lowercase() == "true"
        buildConfigField("boolean", "USE_OWW", "$useOww")
    }
    buildFeatures {
        buildConfig = true
        compose = true
    }

    // Release signing (packaging-signing criterion of the mobile release
    // rubric). The keystore + credentials live OUTSIDE the repo:
    //   ~/.papercusp/secrets/papercup-android-release.keystore
    //   ~/.gradle/gradle.properties → PAPERCUP_RELEASE_KEYSTORE{,_PASSWORD},
    //   PAPERCUP_RELEASE_KEY_ALIAS (see docs/BUILD.md § secrets).
    // Debug/host checks need no signing inputs. Release assembly and bundle
    // entry points require validateReleaseSigning below.
    val hasReleaseKeystore = releaseKeystorePath != null && file(releaseKeystorePath).isFile
    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = file(releaseKeystorePath!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias ?: "papercup"
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        getByName("debug") {
            isMinifyEnabled = false
            manifestPlaceholders["usesCleartextTraffic"] = "true"
        }
        getByName("release") {
            isMinifyEnabled = true
            signingConfigs.findByName("release")?.also { signingConfig = it }
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
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

val validateReleaseSigning by
    tasks.registering {
        group = "verification"
        description = "Require the effective Android release-signing inputs and keystore."
        doLast {
            val values =
                mapOf(
                    "PAPERCUP_RELEASE_KEYSTORE" to releaseKeystorePath,
                    "PAPERCUP_RELEASE_KEYSTORE_PASSWORD" to releaseStorePassword,
                    "PAPERCUP_RELEASE_KEY_ALIAS" to releaseKeyAlias,
                    "PAPERCUP_RELEASE_KEY_PASSWORD" to releaseKeyPassword,
                )
            val missing = values.filterValues { it == null }.keys
            require(missing.isEmpty()) {
                "Android release signing preflight failed; missing external inputs: ${missing.joinToString(", ")}"
            }
            val keystore = file(values.getValue("PAPERCUP_RELEASE_KEYSTORE")!!)
            require(keystore.isFile) {
                "Android release signing preflight failed; keystore does not exist: $keystore"
            }
        }
    }

tasks.matching { it.name == "assembleRelease" || it.name == "bundleRelease" }.configureEach {
    dependsOn(validateReleaseSigning)
}

tasks.named("preBuild").configure {
    dependsOn(generateUniFfiKotlin)
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.3")
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
    // 5.17+ fixes jnidispatch on Android's 16 KB page-size devices.
    implementation("net.java.dev.jna:jna:5.19.1@aar")

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
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.4")

    // (WireGuard tunnel binding removed — mesh is now Defguard self-enrollment
    //  via the system VPN; mobile-apps-revival-redesign D-005.)

    // Phase 10g: Picovoice Porcupine for "hey papercup" wake word.
    // Engine is dormant unless PICOVOICE_ACCESS_KEY is set in
    // android/local.properties (or BuildConfig.PICOVOICE_ACCESS_KEY at
    // build time); WakeWordEngine.kt early-returns otherwise.
    // 4.x ships 16 KB page-size-compatible Android binaries; 3.0.1's
    // arm64-v8a libpv_porcupine.so used 4 KB LOAD alignment.
    implementation("ai.picovoice:porcupine-android:4.0.0")
    // ElevenLabs Conversational AI SDK — voice transport for V1.
    // Pulls LiveKit Android as the WebRTC layer. See docs/VOICE_V1_PLAN.md.
    implementation("io.elevenlabs:elevenlabs-android:0.9.0")

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

    // WI-4967/WI-4966: JVM unit tests (src/test) — UX-contract tests pinning
    // voice failure copy (mic-denial + transport-failure messages).
    testImplementation("junit:junit:4.13.2")

    androidTestImplementation("androidx.test:core:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:runner:1.7.0")

    debugImplementation(composeBom)
    debugImplementation("androidx.compose.ui:ui-tooling")
}
