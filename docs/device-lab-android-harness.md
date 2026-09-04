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
Barnard's asynchronous advertising-success callback. The scanner prints
`DEVICE_LAB_ROLE=scanner READY` only after Barnard receives its first matching
BLE scan callback, then reports
`DEVICE_LAB_BLE_PASS peer=SHORT_ID ms=ELAPSED` on the first
`BarnardEvent.Detection`. A raw `ble_discovery_result` proves that scanning is
delivering results but is not a PASS: the stronger Detection event shows that
Barnard completed peer resolution for the joined event. Each invocation also
prints and logs one terminal, whitespace-free
`RESULT role=... status=PASS|FAIL ...` line. Its outer test boundary includes
runtime-permission setup, Activity launch, the test body, and Activity teardown,
so a failure in any of those phases produces a FAIL line before it propagates.

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

## Human and device prerequisites

This is not an unattended setup procedure. A human operator must first confirm
that both authorized phones are physically present, unlocked, visible in
`adb devices`, and have Bluetooth and location services enabled. The operator
must also confirm which serial is the advertiser and which is the scanner.

After building and installing both APKs with runtime permissions granted, the
device-lab orchestrator invokes the test once per serial. The equivalent
commands are:

```sh
adb -s <advertiser-serial> shell am instrument -w -r \
  -e role advertiser -e eventCode BEID -e holdSeconds 90 \
  -e class org.levarac.beid.devicelab.TwoDeviceBleDiscoveryTest \
  org.levarac.beid.test/androidx.test.runner.AndroidJUnitRunner

adb -s <scanner-serial> shell am instrument -w -r \
  -e role scanner -e eventCode BEID -e timeoutSeconds 60 \
  -e class org.levarac.beid.devicelab.TwoDeviceBleDiscoveryTest \
  org.levarac.beid.test/androidx.test.runner.AndroidJUnitRunner
```

The advertiser invocation runs in the background. The orchestrator waits for
its `DEVICE_LAB_ROLE=advertiser READY` marker before starting the scanner.
`connectedDebugAndroidTest` and the repository's `deviceLabBleTest` task do not
assign different arguments per serial, so they are compilation/developer
guards rather than the two-device orchestration entry point.

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
3. Build and install both APKs, then invoke the documented test class once per
   serial with the explicit role argument.
4. Assign one invocation `role=advertiser`, wait for its READY signal, then
   assign the other `role=scanner`. `connectedDebugAndroidTest` launches the
   same suite independently on every connected device; it does **not** by
   itself coordinate one phone as one BLE role and the second phone as its
   peer.
5. Map zero/nonzero exit to the commit status and archive the XML/HTML output.
6. Only after a real two-device PASS has been demonstrated on emi, remove the
   legacy Flutter harness and manual-skip mechanism in the device-lab
   repository. Those files are intentionally untouched here.
