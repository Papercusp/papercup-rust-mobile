// SPDX-License-Identifier: GPL-3.0-or-later
plugins {
    // Public-release recovery: 8.13.2 is the smallest AGP line with
    // official API 36 support. Gradle 8.14.3 already satisfies its minimum.
    // WI-5033 previously bumped 8.7.3 -> 8.11.2. AGP 8.7.3 fixed some lint-analysis
    // IncompatibleClassChangeError cases but NOT androidx.lifecycle's
    // NonNullableMutableLiveDataDetector, which still crashed
    // :app:lintVitalAnalyzeRelease even after lifecycle-runtime-compose was
    // bumped to 2.9.4 (WI-4983's detector-side theory was insufficient on
    // its own — the crash is a UAST/Kotlin-analysis-API version mismatch
    // between AGP's bundled lint tooling and the detector's compiled
    // bytecode, not just a stale detector version).
    id("com.android.application") version "8.13.2" apply false
    id("org.jetbrains.kotlin.android") version "2.0.21" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.0.21" apply false
    id("com.google.gms.google-services") version "4.4.2" apply false
    id("com.google.firebase.crashlytics") version "3.0.2" apply false
}
