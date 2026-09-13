# beid — native Android (first slice)

First slice of the native (Flutter-free) beid Android app. Kotlin, Jetpack
Compose, consumes the [levarac/barnard](https://github.com/levarac/barnard)
BLE SDK. This mirrors the native host shape described in `ios/README.md` at
the same "first cut, not feature parity" scope — one screen, the
design-system theme, and a compiling SDK dependency.

## Build & run

For local macOS builds, resolve a supported JDK through the repository helper.
It accepts a supported `KMP_JAVA_HOME`, then tries Android Studio JBR 21
(commonly `/Applications/Android Studio.app/Contents/jbr/Contents/Home`),
Homebrew JDK 17, and macOS's Java 17 resolver. AGP 8.11.1 fails under the
ambient system Java 25 with an opaque `BUILD FAILED … What went wrong:
25.0.3` error (no stack trace), so do not rely on the shell default:

```sh
# Start in the repository root.
cd android
JAVA_HOME="$(../scripts/resolve_kmp_java_home.sh)" \
  ./gradlew assembleDebug
```

CI selects its pinned JDK 17 separately. Do not change the repository's
Gradle configuration merely to accommodate an unsupported ambient JDK.

For local test runs, use the repository wrapper from the repository root to
keep routine Gradle noise out of the terminal while retaining the complete
log:

```sh
python3 scripts/run_local_tests.py android \
  :shared:testAndroidHostTest \
  :app:testDebugUnitTest
```

Pass fully qualified Gradle tasks. The wrapper resolves the supported JDK,
prints each requested task outcome and fresh JUnit counts, and saves the full
combined output under `build/local-test-runs/`. A `NO-SOURCE` task or missing,
stale, or malformed JUnit evidence is printed as `EVIDENCE WARNING`; do not
call that run GREEN even when Gradle returned exit 0. If Gradle fails, the
complete raw output and stack trace are printed and Gradle's exit code is
preserved. The wrapper reduces output only—it does not justify replacing the
full covering suite with a focused task.

Gradle also needs to know where the Android SDK is. A fresh checkout has
neither `ANDROID_HOME`/`ANDROID_SDK_ROOT` set nor an `android/local.properties`,
so every task that touches the Android plugin — including
`:app:testDebugUnitTest` and `:shared:testAndroidHostTest` — fails before
running any test code with `SDK location not found`. Point it at a local SDK
once, either by exporting `ANDROID_HOME` (a Homebrew
`android-commandlinetools` install or Android Studio's bundled SDK both work)
or by setting `sdk.dir` in `android/local.properties`, which is gitignored.

**This is a local-only step. CI never hits it** — GitHub-hosted
`ubuntu-latest` runners ship a preinstalled Android SDK with `ANDROID_HOME`
already set. A local `SDK location not found` therefore says nothing about
the state of the PR CI lane.

APK lands at `app/build/outputs/apk/debug/app-debug.apk`. To run it:

```sh
# Start in android/.
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n org.levarac.beid/.MainActivity
```

### Read-only UI scenarios

Debug builds accept an optional intent extra equivalent to iOS's
`-beid-demo-scenario <name>` launch argument:

```sh
adb shell am start -n org.levarac.beid/.MainActivity \
  --es beid-demo-scenario crowdSurge
```

The exact identifiers are `zeroPeersForever`, `crowdSurge`,
`longDisplayNames`, `unidentifiedHeavy`, `signalLostMidway`, and
`appReviewGolden`. A missing or unknown value uses the ordinary real-BLE
application root. Release builds ignore the extra and also use real BLE.

Compose previews inject the same named snapshots directly; see
`scenario/ScenarioPreviews.kt` for representative Event Join and Records
previews. Scenario snapshots contain only screen state and read-only record
rows. The scenario branch does not construct `EventJoinCoordinator`,
`ProofRecordStore`, a signing implementation, ledger machinery, or a
submission path, so fixture data has no writable production input.

## Barnard SDK dependency

beid consumes [levarac/barnard](https://github.com/levarac/barnard) from
Maven Central with the exact coordinate
`implementation("org.levarac:barnard:0.9.2")`. Both the Android application
and the SDK therefore resolve from published, reproducible artifacts; no
submodule or Gradle composite build is required. Verified 2026-09-11 against
`app/build.gradle.kts`. The build file is the authority for the pinned
version; this README explains that dependency.

The SDK includes the signing backend work introduced in the 0.6.0 series:
Android uses Bouncy Castle `bcprov-jdk15to18` (1.81 in the 0.9.2 artifact),
while the Apple SDK uses the vendored libsecp256k1 backend. Both follow the
[Barnard secp256k1 ECDSA profile](https://github.com/levarac/barnard/blob/v0.9.2/specs/158-secp256k1-ecdsa-profile/spec.md),
including canonical low-S signatures and the specified recovery-id rules.
Do not duplicate that cryptographic policy in the host app.

Version 0.9.2 also exposes the public
[B005 v2 envelope encoder](https://github.com/levarac/barnard/blob/v0.9.2/packages/android/barnard/src/main/kotlin/org/levarac/barnard/BarnardB005EnvelopeV2.kt):
`BarnardB005EnvelopeV2.encodeUnsignedEnvelope` assembles and checks the supplied
signed fields, and `encodeContainer` wraps an envelope for transmission. These
SDK APIs do not by themselves establish that an Android venue-device UI is
implemented.

`settings.gradle.kts` provides `mavenCentral()` through
`dependencyResolutionManagement.repositories`. To update the SDK, change the
version in `app/build.gradle.kts`, then verify Central resolution and
compilation from `android/` with the same resolver-backed JDK selection:

```sh
# Start in android/.
JAVA_HOME="$(../scripts/resolve_kmp_java_home.sh)" \
  ./gradlew :app:assembleDebug
```

## Design-system theme

`ui/theme/{Color,Type,Spacing,Theme}.kt` port DESIGN.md's token values into
Compose, mirroring iOS's `DS` namespace (`ios/Beid/DesignSystem/Tokens.swift`)
role-for-role — `BeidTheme.colors.signalActive`, `BeidSpacing.pageMargin`,
etc. Ratification status varies by section, per DESIGN.md itself: §5 Color's
palette *direction* and color *roles* are ratified (Ken, 2026-07-10), though
the exact secondary hex values are still `PROPOSAL — Ken ratification
pending`; §7 Spacing and §8 Shape are ratified; §6 Typography is explicitly
`PROPOSAL — Ken ratification pending` in full — `Type.kt`'s sp values are
this scaffold's own iOS-Dynamic-Type-to-Material3 mapping, not a ratified
spec, and its kdoc says so. This is a values port, not a code port:
`DesignSystem/Tokens.swift`'s Swift is not translated line-by-line, since
Compose's token/theming idioms (`CompositionLocal`, Material3
`ColorScheme`/`Typography`) differ structurally from SwiftUI's. Colors are
hardcoded (not read from `Colors.xcassets`, which is iOS-only tooling) — see
`Color.kt`'s kdoc for the source hex values and DESIGN.md §5's table for the
canonical values if they change.

Not yet ported (out of scope for this slice, DESIGN.md marks them
`PROPOSAL — Ken ratification pending` anyway): `DS.Motion` springs (Compose
animation specs are a follow-up once a motion-bearing screen lands) and
`DS.Artwork.proofCardGradient` (no proof-card screen exists yet on Android).

## One working screen: Join an event

`ui/screens/EventJoinScreen.kt` is the scaffold's proof that the published SDK
resolves, compiles, and runs: enter an event code → tap "Join event" →
`EventJoinCoordinator` calls `BarnardEngine.requestPermissions` → the real
Android BLE runtime-permission dialog appears → on grant, `joinEvent(code)` +
`startAuto()` start scan+advertise and the screen reflects a "Sensing for
nearby peers…" state. Verified end-to-end on a Pixel 6 API 33 emulator
(screenshot attached to the PR).

This mirrors the manual event-code-entry slice landing on iOS in parallel
(scope note in the task brief: a stub/simple version is intentional here, not
a placeholder for missing work). `EventJoinCoordinator`
(`sensing/EventJoinCoordinator.kt`) is a thin wrapper, not a full port of
iOS's `SensingCoordinator` — no BLE-off/signal-lost recovery states. A native
`persistence/UnsentWindowLedgerStore.kt` is wired into the sensing lifecycle:
`WindowObservationAccumulator` opens and closes rows on it as windows are
observed, and `WindowObservationSubmissionDrain` (beid#525) submits durably
closed windows to the event's operator. What remains is the rest of iOS's
post-join flow (sensing → event found → recording with a one-time proof
entrance, plus signal-loss recovery and collection home), which stays
follow-up work.

**Why `BarnardEngine` is owned by `MainActivity`, not the composable**:
`requestPermissions` is Activity-driven — the hosting `Activity` must forward
`onRequestPermissionsResult` back into the *same* engine instance for the
pending callback to ever resolve. A
composable-scoped instance would have no way to receive that callback, so
`MainActivity` creates one `EventJoinCoordinator` in `onCreate`, forwards
`onRequestPermissionsResult` into it, and disposes it in `onDestroy`.

## App shell

Single-activity (`MainActivity`) hosting one Compose tree, Navigation-Compose
(`navigation/AppNavHost.kt`, `navigation/Screen.kt`) as the Compose analog of
iOS's `RootView` + `AppCoordinator`. `minSdk` is 26 (not the barnard
library's floor of 24) — API 26 is what adaptive `neverForLocation` BLE scan
permission semantics assume cleanly and keeps the launcher-icon story simple
(no legacy per-density mipmap buckets needed); revisit if a real product
reason to support API 24–25 shows up.

## Localization

Following the root `AGENTS.md` process, adapted for Android tooling: Android
[string resources](https://developer.android.com/guide/topics/resources/string-resource)
(`res/values*/strings.xml`) are this platform's equivalent of iOS's SwiftUI
String Catalog. The target set is `en` only — owner decision 2026-08-21
(`DECISIONS.md`, MTG 2026-08-20), superseding the 2026-08-19 `en`+`ja`
reduction. `values-ja/` was removed in the same change; `values-b+zh+Hans/`,
`values-es/` and `values-fr/` went on 2026-08-19. All are recoverable from git
history.

**Shipping one locale does not mean hardcoding copy.** User-facing text still
goes through `res/values/strings.xml`, never inline in a Composable, and
design-system components take strings as parameters rather than embedding
them (beid#119's contract). That is what keeps adding a locale later a matter
of configuration rather than a rewrite.

With `en` as the only target there is nothing to mark as needs-review today.
The convention to restore if a locale is ever added back: Android's resource
format has no built-in `needs_review` state the way Xcode String Catalogs do,
so each translated file carried an explicit XML comment marking it as
machine-drafted and un-reviewed. A missing or untranslated string falls back
to the default `values/` (English) at runtime, which is what made shipping
partial translations safe.

## Testing

**Decision: Compose UI tests run Robolectric-backed as JVM tests under
`:app:testDebugUnitTest` (`src/test`), not as instrumented `androidTest`.**
This is deliberate, not a placeholder pending emulator infrastructure:

- CI's Android job (`.github/workflows/pr-ci.yml`, see the [PR CI
  contract](../AGENTS.md#pr-ci)) only *runs* `:shared:testAndroidHostTest`,
  `:app:testDebugUnitTest`, and `:app:assembleDebug` on Ubuntu — no emulator,
  no `connectedAndroidTest` step. It additionally *compiles* the instrumented
  source set via `:app:compileDebugAndroidTestKotlin`, which catches
  `androidTest` code that no longer builds against the main sources, but it
  never executes those tests. An instrumented `androidTest` would not run
  in CI today without adding emulator infrastructure, which is a call bigger
  than any single feature slice and not something to add incidentally.
- Robolectric + Compose's JVM `createComposeRule()` gives real Compose
  semantics-tree assertions (`onNodeWithTag`, `onNodeWithText`,
  `performClick`, ...) inside a plain JVM unit test, so it runs wherever
  `:app:testDebugUnitTest` already runs, CI included, with zero CI changes
  required.

Gradle wiring this needs in `app/build.gradle.kts` (current stable versions
as of 2026-08-19 — reverify before reusing if this doc is old):
- `android { testOptions { unitTests { isIncludeAndroidResources = true } } }`
  — required because screens use `stringResource(...)`; without this,
  Robolectric cannot resolve Android resources from a unit test.
- `testImplementation(platform("androidx.compose:compose-bom:<version>"))` —
  BOM alignment applied to `implementation` does not automatically cover
  `testImplementation`; declare the same BOM platform in both configurations.
- `testImplementation("androidx.compose.ui:ui-test-junit4")` for
  `createComposeRule()` and the `onNodeWith*`/assertion API.
- `debugImplementation("androidx.compose.ui:ui-test-manifest")` — **not**
  `testImplementation`. Its bundled manifest (a launcher `ComponentActivity`
  that `createComposeRule()` launches under the hood via `ActivityScenario`)
  must merge into the **debug variant's** manifest, since that's the
  manifest Robolectric resolves for `:app:testDebugUnitTest`.
  `testImplementation` dependencies never contribute to a variant's own
  manifest merge, so declaring it there compiles fine but fails at test
  runtime with `Unable to resolve activity for Intent ... cmp=.../
  androidx.activity.ComponentActivity`.
- `testImplementation("org.robolectric:robolectric:<version>")` and
  `testImplementation("androidx.test.ext:junit:<version>")` for the
  `@RunWith(RobolectricTestRunner::class)` + `@Config(sdk = [...])` test
  harness itself.
- `testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:<version
  matching kotlinx-coroutines-android>")` for `Dispatchers.setMain(...)` in
  plain (non-Robolectric) ViewModel unit tests that use `viewModelScope` —
  without a registered test Main dispatcher, `viewModelScope.launch { ... }`
  throws `IllegalStateException: Module with the Main dispatcher had failed
  to initialize` on a plain JVM test. Robolectric tests don't need this: its
  shadowed `Looper.getMainLooper()` satisfies `Dispatchers.Main` on its own.
- `compileSdk`/AGP pin note: `androidx.lifecycle:lifecycle-viewmodel-compose`
  2.11.0+ requires `compileSdk 37` and AGP 9.1.0+; this project pins
  `compileSdk = 36` / AGP 8.11.1 (see `app/build.gradle.kts`), so ViewModel
  work here uses `lifecycle-viewmodel-compose:2.10.0`, the newest version
  compatible with the current compileSdk/AGP pin. Bump both together if this
  repo's compileSdk/AGP moves to 37+/9.1.0+.

## What's deliberately not here

- No app-specific R8 keep rules are currently required because the app uses
  the `JsonElement` tree API directly rather than reflection or generated
  serializers. Release builds enable minification with the Android Gradle
  plugin's optimized defaults and the intentionally empty
  `proguard-rules.pro`; debug builds remain unminified.
- No instrumentation or device E2E tests. See "Testing" above for why Compose
  UI coverage is Robolectric-backed JVM tests instead. JVM unit tests
  currently cover the app-to-`shared/` bridge, the native unsent-window
  ledger store, and the Event Join ViewModel/screen. For the current hosted
  job set and the GitHub Actions / Xcode Cloud division, use the
  repository's authoritative [PR CI contract](../AGENTS.md#pr-ci) together
  with its executable workflow, `.github/workflows/pr-ci.yml`.
