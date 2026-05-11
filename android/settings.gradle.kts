// SPDX-License-Identifier: GPL-3.0-or-later
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        // LiveKit Android (transitive of io.elevenlabs:elevenlabs-android)
        // depends on com.github.davidliu:audioswitch, which only lives on
        // JitPack.
        maven("https://jitpack.io")
    }
}
rootProject.name = "Papercup"
include(":app")
