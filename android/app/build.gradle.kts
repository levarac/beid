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
// Defaulted to the same operator artifact URLs `ios/project.yml` bakes into
// BEID_EVENT_DEFINITION_URL_TEMPLATE and BEID_EVENT_KEY_SET_URL_TEMPLATE.
// Both defaulted to the empty string until beid#584, and nothing in this
// repository, in CI, or in the documented build commands ever supplied them,
// so every Android build shipped with no definition fetcher at all: the
// event-code-hash lookup succeeded, `resolveEventDefinition` then threw
// NOT_CONFIGURED, and a discovered event sat at "Waiting for event
// verification" forever while iOS verified the same beacon. A `-P` override
// still wins, which is how a lab or a different operator is pointed
// elsewhere; the default only decides what an unparameterized build does.
val definitionUrlTemplate = providers.gradleProperty("beid.definitionUrlTemplate")
    .orElse("https://parallax-observation-operator.levarac.workers.dev/artifacts/definitions/{definitionHash}")
val eventKeySetUrlTemplate = providers.gradleProperty("beid.eventKeySetUrlTemplate")
    .orElse("https://parallax-observation-operator.levarac.workers.dev/artifacts/key-sets/{keySetDigest}")
val eventCodeLookupUrlTemplate = providers.gradleProperty("beid.eventCodeLookupUrlTemplate")
    .orElse("https://parallax-observation-operator.levarac.workers.dev/v1/events/by-code/{code}")
val eventCodeHashLookupUrlTemplate = providers.gradleProperty("beid.eventCodeHashLookupUrlTemplate")
    .orElse("https://parallax-observation-operator.levarac.workers.dev/v1/events/by-code-hash/{hash}")

// Blank or absent both mean "not produced by CI". Never surface 0 or an empty
// string: the version row must say "local" so a screenshot from a developer
// build can never be mistaken for a delivered one (beid#491).
val gitHeight: String =
    (project.findProperty("gitHeight") as? String)?.takeIf { it.isNotBlank() } ?: "local"

android {
    namespace = "org.levarac.beid"
    compileSdk = 36

    defaultConfig {
        applicationId = "org.levarac.beid"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        buildConfigField(
            "String",
            "EVENT_REGISTRY_READER_ADDRESS",
            registryReaderAddress.get().asBuildConfigString(),
        )
        buildConfigField("String", "EVENT_CODE_LOOKUP_URL_TEMPLATE", eventCodeLookupUrlTemplate.get().asBuildConfigString())
        buildConfigField("String", "EVENT_CODE_HASH_LOOKUP_URL_TEMPLATE", eventCodeHashLookupUrlTemplate.get().asBuildConfigString())
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
            "EVENT_KEY_SET_URL_TEMPLATE",
            eventKeySetUrlTemplate.get().asBuildConfigString(),
        )
        // Git height = the build position shared with iOS (beid#491). CI passes
        // -PgitHeight; a developer build has no property and reads "local".
        // versionCode above is deliberately untouched: the store number and the
        // build position are different numbers with different owners.
        buildConfigField("String", "GIT_HEIGHT", gitHeight.asBuildConfigString())
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
        // Explicit Lab boundary; shipping debug/release variants remain unchanged.
        create("labDebug") {
            initWith(getByName("debug"))
            applicationIdSuffix = ".lab"
            matchingFallbacks += listOf("debug")
            buildConfigField("String", "LAB_PROTOCOL_VERSION", "\"1\"")
        }
        release {
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
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

    sourceSets.getByName("test").resources.srcDir("../../shared/src/commonTest/fixtures")

}

dependencies {
    implementation(project(":shared"))

    // MetaMask's native Android SDK is archived upstream; pin the last Maven
    // Central release deliberately while the app migrates to a maintained
    // replacement. No relay or transaction API is used by this app.
    implementation("io.metamask.androidsdk:metamask-android-sdk:0.6.6")

    // Native (Flutter-free) BLE mutual-observation SDK published to Maven Central.
    implementation("org.levarac:barnard:0.9.2")
    add("labDebugImplementation", "com.squareup.okhttp3:okhttp:4.12.0")

    implementation(platform("androidx.compose:compose-bom:2026.06.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    // Icons for BeidGlyph/BeidHeroHeader/BeidStateScreen (beid#338).
    //
    // This artifact is carrying exactly three symbols that material-icons-core
    // does not have: Bluetooth (BluetoothPermissionScreen), BluetoothDisabled
    // (BluetoothOffScreen) and AutoAwesome (EventFoundScreen). Warning
    // (SignalLostScreen) is in core and does not need this. Counts were read
    // from the resolved jars, not the library's docs: core ships 49 Filled.*
    // icons, extended ships 2083.
    //
    // Three symbols is a thin justification for 2083. The release build uses
    // R8 to trim unreferenced icons; debug remains unminified so its build and
    // development behavior do not change (beid#379).
    //
    // Hand-drawing these was considered and rejected. The illustrations in
    // ui/designsystem/Illustrations.kt were transcribed from SVG sources in
    // this repository; these three have no source here, so drawing them
    // would be freehand approximation of recognizable system iconography.
    // Transcription and approximation are not the same operation.
    //
    // Versioned by the same BOM platform as the rest of Compose, not an
    // independent pin.
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.navigation:navigation-compose:2.9.8")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.10.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.10.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    // Manual JsonObject/JsonPrimitive tree building (no @Serializable, no
    // kotlin("plugin.serialization") compiler plugin needed) — same version
    // and usage style already established by shared/build.gradle.kts and
    // e.g. EtherscanRestAdapter.kt, extended to :app for BindingRecordStore/
    // SelfProofRecordStore (beid#125).
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")

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
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:rules:1.7.0")
}

val verifyDeviceLabBleTests by tasks.registering {
    group = "verification"
    description = "Fails unless the device-lab BLE instrumentation suite exists."

    doLast {
        val testSources = fileTree("src/androidTest") {
            include("**/*.kt", "**/*.java")
        }
        if (testSources.isEmpty) {
            throw GradleException(
                "No Android instrumented tests exist in app/src/androidTest. " +
                    "A hardware BLE suite must be added before deviceLabBleTest can report PASS.",
            )
        }
    }
}

tasks.matching { it.name == "connectedDebugAndroidTest" }.configureEach {
    mustRunAfter(verifyDeviceLabBleTests)
}

tasks.register("deviceLabBleTest") {
    group = "verification"
    description = "Runs the debug instrumentation suite on every adb-connected device."
    dependsOn(verifyDeviceLabBleTests, "connectedDebugAndroidTest")
}
