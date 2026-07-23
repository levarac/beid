# beid — native Android (first slice)

First slice of the native (Flutter-free) beid Android app. Kotlin, Jetpack
Compose, consumes the [levarac/barnard](https://github.com/levarac/barnard)
BLE SDK. This mirrors `ios/`'s scaffold slice (13-screen SwiftUI scaffold,
`ios/README.md`) at the same "first cut, not feature parity" scope — one
screen, the design-system theme, and a compiling SDK dependency.

## Build & run

Requires **JDK 17** — AGP 8.11.1 fails to run under JDK 25 with an opaque
`BUILD FAILED … What went wrong: 25.0.3` error (no stack trace). If your
default `JAVA_HOME` is newer, point Gradle at 17 explicitly:

```sh
brew install openjdk@17   # if you don't have it
cd android
JAVA_HOME=$(brew --prefix openjdk@17)/libexec/openjdk.jdk/Contents/Home ./gradlew assembleDebug
```

Or set `org.gradle.java.home` in `gradle.properties` / your global Gradle
config if you'd rather not pass `JAVA_HOME` per invocation.

APK lands at `app/build/outputs/apk/debug/app-debug.apk`. To run it:

```sh
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n org.levarac.beid/.MainActivity
```

## Barnard SDK dependency

**What we did**: `android/vendor/barnard` is a **git submodule** pointing at
[levarac/barnard](https://github.com/levarac/barnard) (public repo, no
credentials needed), pinned to `54385d2` (origin/main HEAD as of this slice —
the commit that added the Android SDK, barnard#56, plus a follow-up
permission-callback fix). `settings.gradle.kts` wires it in as a **Gradle
composite build**:

```kotlin
includeBuild("vendor/barnard/packages/android/barnard") {
    dependencySubstitution {
        substitute(module("network.greeting.barnard:barnard")).using(project(":"))
    }
}
```

`app/build.gradle.kts` then depends on it as an ordinary coordinate:
`implementation("network.greeting.barnard:barnard:1.0-SNAPSHOT")`.

**Why this differs from iOS's approach**: iOS consumes barnard as a remote
SwiftPM package pinned to an exact release (see `ios/README.md` "Barnard SDK
dependency"); Android keeps the submodule until barnard publishes to Maven
Central, at which point a coordinate dependency becomes possible.
Gradle has no equivalent constraint: `includeBuild` can point at any
subdirectory of any local checkout. That local-checkout requirement is the
only remaining wrinkle — a plain relative `includeBuild("../../barnard/...")`
(the pattern barnard's own `examples/android-native` uses, since the example
lives inside the same monorepo) would only work if every developer and CI
runner happened to check out `barnard` at exactly that relative path next to
`beid`, which isn't guaranteed. A git submodule resolves that: the path is
now *inside this repo*, deterministic, and (since levarac/barnard is public)
cloneable with no auth setup — `git submodule update --init` is enough,
including in CI.

**Trade-off accepted**: this vendors the whole `barnard` monorepo (all
platforms' packages, examples, docs), not just `packages/android/barnard`.
Git submodules don't support a lightweight "only this subdirectory" checkout
without extra sparse-checkout configuration; given this is a first scaffold
slice, the simplicity of a plain submodule won out over minimizing checkout
size. A sparse submodule (or splitting `packages/android/barnard` into its
own repo once it's published) is a reasonable follow-up if checkout size
becomes a real problem.

**Follow-up**: once barnard publishes the Android package to Maven (its own
`README.md` already notes this as the intended end state — "publish to Maven
once this package is released"), switch `settings.gradle.kts` /
`app/build.gradle.kts` to a normal `mavenCentral()` coordinate and delete the
submodule.

**Bumping the pin**: `cd android/vendor/barnard && git fetch && git checkout
<new-sha> && cd ../.. && git add android/vendor/barnard && git commit`.

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

`ui/screens/EventJoinScreen.kt` is the scaffold's proof that the vendored SDK
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
iOS's `SensingCoordinator` — no BLE-off/signal-lost recovery states, no
persistence. Those, plus the rest of iOS's 13-screen flow (sensing → event
found → verifying → verified → proof collected → collection home, etc.), are
follow-up slices.

**Why `BarnardEngine` is owned by `MainActivity`, not the composable**:
`requestPermissions` is Activity-driven — the hosting `Activity` must forward
`onRequestPermissionsResult` back into the *same* engine instance for the
pending callback to ever resolve (per `vendor/barnard`'s own README). A
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
String Catalog, covering the same locale set — `en` (source, sentence-case,
DESIGN.md §15 vocabulary/forbidden-term rules) + `ja`, `zh-Hans` (as
`values-b+zh+Hans`, the modern BCP-47 qualifier), `es`, `fr`. All four
translated locales are machine-drafted starting points.

Android's resource format has no built-in `needs_review` state the way Xcode
String Catalogs do; each translated file carries an explicit XML comment
marking it as machine-drafted and un-reviewed instead — see
`values-ja/strings.xml` etc. A missing or untranslated string falls back to
the default `values/` (English) at runtime, same graceful-degradation
property as the iOS process describes, so shipping partial/needs-review
translations in this PR is safe.

## What's deliberately not here

- No CI workflow wiring (task scope: prove `./gradlew assembleDebug`
  succeeds locally; CI wiring is a stated follow-up).
- No ProGuard/R8 minification config beyond Gradle defaults (`isMinifyEnabled
  = false` for debug and release, matching barnard's own example app — real
  release signing/minification is a pre-launch concern, not scaffold scope).
- No unit/instrumentation tests yet (iOS's scaffold PR landed
  `BeidNativeTests` alongside its views; the Android equivalent is a
  reasonable immediate follow-up rather than bundling it into an
  already-broad first slice).
