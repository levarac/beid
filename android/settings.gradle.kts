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

// Flutter-free: consumes vendor/barnard/packages/android/barnard directly as
// a composite build, the same pattern barnard's own examples/android-native
// uses against its sibling packages/android/barnard. See android/README.md
// "Barnard SDK dependency" for why this repo vendors the whole barnard repo
// as a submodule instead of a plain relative includeBuild path.
includeBuild("vendor/barnard/packages/android/barnard") {
    dependencySubstitution {
        substitute(module("network.greeting.barnard:barnard")).using(project(":"))
    }
}
