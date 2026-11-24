pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        // Large Robolectric SDK jars can hit Maven Central's shared-runner rate limit.
        // Only this module uses the mirror; Central remains the missing-module fallback.
        maven {
            name = "robolectricCentralMirror"
            url = uri("https://maven-central.storage-download.googleapis.com/maven2/")
            content {
                includeModule("org.robolectric", "android-all-instrumented")
            }
        }
        google {
            content {
                excludeModule("org.robolectric", "android-all-instrumented")
            }
        }
        mavenCentral()
    }
}

rootProject.name = "Beid"

include(":app")
include(":shared")
project(":shared").projectDir = file("../shared")

// Optional local candidate used for the Barnard wallet-verifier API. The
// published 0.9.2 pin remains the default; CI and consumers do not depend on
// an unreleased artifact.
providers.gradleProperty("beid.barnardDir").orNull?.let { candidate ->
    includeBuild(candidate) {
        dependencySubstitution {
            substitute(module("org.levarac:barnard")).using(project(":"))
        }
    }
}
