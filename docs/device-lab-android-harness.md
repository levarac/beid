# Android device-lab harness handoff

This document covers only the integration surface available in the beid
repository. The device-lab configuration, its runner scripts, commit-status
reporting, and `last_tested_sha.beid` are owned by the separate device-lab
repository and must be changed there by someone who can test on emi.

## Two-device BLE scenario

`org.levarac.beid.devicelab.TwoDeviceBleDiscoveryTest` is the physical-device
instrumentation entry point. The runner assigns each invocation a `role` of
`advertiser` or `scanner`. Both roles use `eventCode` (default `BEID`); the
advertiser remains active for `holdSeconds` (default 90), and setup or peer
observation must finish within `timeoutSeconds` (default 60).

The advertiser prints and logs `DEVICE_LAB_ROLE=advertiser READY` only after
Barnard reports that advertising started. The scanner reports
`DEVICE_LAB_BLE_PASS peer=SHORT_ID ms=ELAPSED` on the first
`BarnardEvent.Detection`. A raw `BarnardEvent.RssiUpdate` records that an
advertisement was visible but is not a PASS: the stronger Detection event
shows that Barnard completed peer resolution for the joined event. Timeout
failures distinguish a scan that never started, no visible advertisement,
and a visible advertisement that never became a Detection.

The suite grants runtime BLE permissions before `MainActivity` launches. On
API 26 and 27 this is `ACCESS_FINE_LOCATION`, matching the permission merged
from Barnard's AAR; it does not depend on an interactive permission dialog.

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
`android/app/build/outputs/apk/debug/app-debug.apk`. The instrumentation test
APK is assembled under
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
or Java tests. The device-lab runner must assign the two roles explicitly;
launching the same unconfigured suite on both devices fails closed rather
than becoming a false green commit status.

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
4. Assign one invocation `role=advertiser`, wait for its READY signal, then
   assign the other `role=scanner`. `connectedDebugAndroidTest` launches the
   same suite independently on every connected device; it does **not** by
   itself coordinate one phone as one BLE role and the second phone as its
   peer.
5. Map zero/nonzero exit to the commit status and archive the XML/HTML output.
6. Only after a real two-device PASS has been demonstrated on emi, remove the
   legacy Flutter harness and manual-skip mechanism in the device-lab
   repository. Those files are intentionally untouched here.
