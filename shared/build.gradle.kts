import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.swiftexport.ExperimentalSwiftExportDsl
import org.gradle.api.tasks.Copy

plugins {
    id("org.jetbrains.kotlin.multiplatform")
    id("com.android.kotlin.multiplatform.library")
}

kotlin {
    androidLibrary {
        namespace = "org.levarac.beid.shared"
        compileSdk = 36
        minSdk = 26

        withHostTestBuilder {}

        compilerOptions {
            jvmTarget.set(JvmTarget.JVM_17)
        }
    }

    iosArm64()
    iosSimulatorArm64()

    @OptIn(ExperimentalSwiftExportDsl::class)
    swiftExport {
        moduleName = "BeidSharedKit"
        flattenPackage = "org.levarac.beid.shared"
    }

    sourceSets {
        commonMain {
            dependencies {
                implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0")
                implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
            }
        }

        commonTest {
            dependencies {
                implementation(kotlin("test"))
                implementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
            }
        }

        getByName("androidHostTest") {
            dependencies {
                implementation("junit:junit:4.13.2")
            }
        }
    }
}

// Kotlin/Native does not automatically package commonTest resources into the test executable.
// Keep the existing loader's stable processedResources layout populated for both native targets.
val commonTestResourceDirectory = layout.projectDirectory.dir("src/commonTest/resources")
val copyIosSimulatorArm64TestResources = tasks.register<Copy>("copyIosSimulatorArm64TestResources") {
    from(commonTestResourceDirectory)
    into(layout.buildDirectory.dir("processedResources/iosSimulatorArm64/test"))
}
val copyIosArm64TestResources = tasks.register<Copy>("copyIosArm64TestResources") {
    from(commonTestResourceDirectory)
    into(layout.buildDirectory.dir("processedResources/iosArm64/test"))
}
tasks.matching { it.name == "iosSimulatorArm64Test" }.configureEach {
    dependsOn(copyIosSimulatorArm64TestResources)
}
tasks.matching { it.name == "iosArm64Test" }.configureEach {
    dependsOn(copyIosArm64TestResources)
}

// beid#403: the cross-repo comparison needs the sibling Parallax checkout, and it
// must find it WITHOUT consulting the working directory. Gradle knows this module's
// project directory regardless of where the wrapper was invoked from, so the repo
// root is derived here and handed to the JVM test task rather than guessed there.
// Its absence is reported by the test as "cannot tell", never as "no checkout".
tasks.withType<Test>().configureEach {
    systemProperty("beid.repoRoot", layout.projectDirectory.dir("..").asFile.canonicalPath)

    // beid#415: PARALLAX_REPO decides whether the cross-repo comparison runs at all, but
    // an environment variable is not a task input, so Gradle reused a result produced
    // under a different answer. Observed 2026-09-09: a run with PARALLAX_REPO set, then
    // the same task with it unset, reported UP-TO-DATE and never re-executed -- the
    // comparison silently did not run and the build was green. Declaring the variable as
    // an input makes changing it invalidate the task. This deliberately does NOT call
    // environment(): an empty value would be read back as a configured-but-missing
    // checkout and fail loudly, which is the opposite of the unset-means-skip half of
    // the contract in ParallaxEventDefinitionSourceChecksumTest.
    inputs.property(
        "parallaxRepo",
        providers.environmentVariable("PARALLAX_REPO").orElse(""),
    )

    // A skip that prints nothing is indistinguishable from a test that passed
    // (beid#403). The cross-repo comparison skips on every machine without a
    // Parallax checkout -- CI included -- and until now the only trace was a
    // count in an HTML report nobody opens. Printing the skip and its reason
    // costs one line of console output and makes the difference visible.
    testLogging {
        events("skipped", "failed")
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
        showCauses = true
        showStackTraces = false
    }
}
