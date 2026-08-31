# Android device-lab harness handoff

This document covers only the integration surface available in the beid
repository. The device-lab configuration, its runner scripts, commit-status
reporting, and `last_tested_sha.beid` are owned by the separate device-lab
repository and must be changed there by someone who can test on emi.

## Current limitation

There is **no two-device BLE test suite** in this repository yet. The sole
`androidTest` class is an always-failing sentinel that makes this gap visible
to automation rather than allowing an empty instrumentation run to pass. The
tests under `android/app/src/test` are JVM tests (some use Robolectric); they cannot
exercise physical BLE radios. In particular, there is no test class, protocol
for assigning central/peripheral roles, or cross-device success oracle that a
runner can select today.

Do not interpret an empty Android instrumentation run as a PASS. The
repository task described below therefore deliberately fails while the suite
is absent. Defining the hardware scenario and adding that suite remain
required work, and need coordination with Barnard and access to two physical
devices.

## Build from a checkout

The checkout needs a normal Android build environment: an Android SDK exposed
through `ANDROID_HOME` (or `ANDROID_SDK_ROOT`) and JDK 17 or 21. It does not
need Flutter, a Barnard checkout, a composite build, or repository-local
secrets. From the repository root, run:

```sh
cd android
JAVA_HOME="$(../scripts/resolve_kmp_java_home.sh)" \
  ./gradlew --no-daemon :app:assembleDebug :app:assembleDebugAndroidTest
```

The application APK is written to
`android/app/build/outputs/apk/debug/app-debug.apk`. The sentinel ensures an
instrumented test APK is also assembled under
`android/app/build/outputs/apk/androidTest/debug/`. A zero exit status means
both APK assembly tasks succeeded; any nonzero status is a build failure and
must be reported as FAIL by the device-lab runner.

## Unattended instrumentation entry point

With the two devices visible in `adb devices` and no other Android devices or
emulators attached, the device-lab runner can invoke:

```sh
cd android
JAVA_HOME="$(../scripts/resolve_kmp_java_home.sh)" \
  ./gradlew --no-daemon :app:deviceLabBleTest
```

`deviceLabBleTest` is a stable repository entry point around
`connectedDebugAndroidTest`. It runs the debug instrumentation test APK on
each adb-connected device and returns Gradle's exit code. It also has a guard
that exits nonzero with an explicit error if `src/androidTest` has no Kotlin
or Java tests. Until the hardware suite replaces
`DeviceLabBleSuiteNotImplementedTest`, that sentinel itself fails on every
device. Both mechanisms prevent the current gap from becoming a false green
commit status.

Android Gradle Plugin writes machine-readable connected-test results below
`android/app/build/outputs/androidTest-results/connected/debug/` and the HTML
report below `android/app/build/reports/androidTests/connected/debug/`. The
device-lab runner should archive both paths even on failure. A zero task exit
is the only PASS signal; a nonzero exit, missing results, disconnected device,
or fewer/more than exactly two authorized physical device serials is FAIL.

## What the device-lab side still must implement

1. Start from a clean checkout of the commit being tested and provide its
   Android SDK and supported `KMP_JAVA_HOME`/JDK installation.
2. Verify `adb devices` contains exactly two authorized physical devices and
   no emulator. Record both serials in the lab log (not in a public commit
   status description).
3. Build the APKs, then invoke `:app:deviceLabBleTest`; do not call `adb
   shell am instrument` with a guessed class name.
4. When a real BLE suite lands, add whatever explicit role assignment and
   synchronization that suite specifies. `connectedDebugAndroidTest` launches
   the same suite independently on every connected device; it does **not** by
   itself coordinate one phone as one BLE role and the second phone as its
   peer.
5. Map zero/nonzero exit to the commit status and archive the XML/HTML output.
6. Only after a real two-device PASS has been demonstrated on emi, remove the
   legacy Flutter harness and manual-skip mechanism in the device-lab
   repository. Those files are intentionally untouched here.
