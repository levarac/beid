pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        google()
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
