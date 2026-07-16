// SPDX-License-Identifier: GPL-3.0-or-later
plugins {
    // 8.7.3: fixes the AGP 8.7.2 lint-analysis IncompatibleClassChangeError
    // (androidx.lifecycle NonNullableMutableLiveDataDetector crashing
    // :app:lintVitalAnalyzeRelease — WI-4983).
    id("com.android.application") version "8.7.3" apply false
    id("org.jetbrains.kotlin.android") version "2.0.21" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.0.21" apply false
    id("com.google.gms.google-services") version "4.4.2" apply false
    id("com.google.firebase.crashlytics") version "3.0.2" apply false
}
