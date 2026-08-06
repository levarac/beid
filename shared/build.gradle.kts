import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.swiftexport.ExperimentalSwiftExportDsl

plugins {
    id("org.jetbrains.kotlin.multiplatform")
    id("com.android.kotlin.multiplatform.library")
}

group = "org.levarac.beid"
version = "0.1.0"

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
        commonMain {}
        commonTest {
            dependencies {
                implementation(kotlin("test"))
            }
        }
        androidMain {}
        getByName("androidHostTest") {}
        iosMain {}
        iosTest {}
    }
}
