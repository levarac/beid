plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

fun String.asBuildConfigString(): String =
    "\"" + replace("\\", "\\\\").replace("\"", "\\\"") + "\""

val registryReaderAddress = providers.gradleProperty("beid.registryReaderAddress")
    .orElse("0xd4852f8526A1555A1b2C34145f0eCDA412a53c51")
val etherscanApiKey = providers.gradleProperty("beid.etherscanApiKey").orElse("")
val definitionUrlTemplate = providers.gradleProperty("beid.definitionUrlTemplate").orElse("")
val eventKeySetHex = providers.gradleProperty("beid.eventKeySetHex").orElse("")

android {
    namespace = "org.levarac.beid"
    compileSdk = 36

    defaultConfig {
        applicationId = "org.levarac.beid"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        buildConfigField(
            "String",
            "EVENT_REGISTRY_READER_ADDRESS",
            registryReaderAddress.get().asBuildConfigString(),
        )
        buildConfigField(
            "String",
            "ETHERSCAN_API_KEY",
            etherscanApiKey.get().asBuildConfigString(),
        )
        buildConfigField(
            "String",
            "EVENT_DEFINITION_URL_TEMPLATE",
            definitionUrlTemplate.get().asBuildConfigString(),
        )
        buildConfigField(
            "String",
            "EVENT_KEY_SET_HEX",
            eventKeySetHex.get().asBuildConfigString(),
        )
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
        buildConfig = true
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }

    testOptions {
        unitTests {
            // Robolectric-backed unit tests (see android/README.md "Testing")
            // resolve stringResource(...) and other Android resources, which
            // requires the unit test classpath to include merged app resources.
            isIncludeAndroidResources = true
        }
    }
}

dependencies {
    implementation(project(":shared"))

    // Native (Flutter-free) BLE mutual-observation SDK published to Maven Central.
    implementation("org.levarac:barnard:0.3.0")

    implementation(platform("androidx.compose:compose-bom:2026.06.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.navigation:navigation-compose:2.9.8")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.10.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")

    debugImplementation("androidx.compose.ui:ui-tooling")
    testImplementation(kotlin("test"))

    // Robolectric-backed Compose unit tests (see android/README.md "Testing").
    testImplementation(platform("androidx.compose:compose-bom:2026.06.01"))
    testImplementation("androidx.compose.ui:ui-test-junit4")
    // debugImplementation (not testImplementation): its bundled AndroidManifest.xml
    // (declaring a launcher ComponentActivity for createComposeRule()) must merge into
    // the *debug variant's* manifest, since that's what Robolectric resolves for
    // :app:testDebugUnitTest — testImplementation dependencies never contribute to a
    // variant's own manifest merge.
    debugImplementation("androidx.compose.ui:ui-test-manifest")
    testImplementation("org.robolectric:robolectric:4.15.1")
    testImplementation("androidx.test.ext:junit:1.3.0")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
}
