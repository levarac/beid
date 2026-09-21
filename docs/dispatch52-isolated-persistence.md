# Android persistence proof without resetting an existing installation

The persistence fixture writes a synthetic signed observation to the real
production stores. Use a separate applicationId on a physical device whose
normal installation contains data. Never clear or uninstall the normal app
to make this test pass. The opt-in init script changes only the debug package
to `org.levarac.beid.persistenceproof`; its test package targets that same UID.
Release and `labDebug` packages are unchanged. No production source or iOS
behavior changes are part of this Android instrumentation fix.

From `android/`, build with the repository JDK resolver and configured Android SDK:

```sh
JAVA_HOME="$(../scripts/resolve_kmp_java_home.sh)" ./gradlew \
  --init-script tools/dispatch52-isolated.init.gradle \
  :app:assembleDebug :app:assembleDebugAndroidTest
```

Check both APK applicationIds and the instrumentation target before installing
them on the explicitly selected device. Install the first time without `-r`
so an unexpected existing package fails rather than silently replacing it.
For subsequent fixture fixes, update only this isolated test APK, preserving
the existing isolated app data so rerun behavior is exercised too.

Run one method in each instrumentation invocation, with the target package
explicitly provided. Do not run the whole class in one process:

```sh
adb -s <SERIAL> shell am instrument -w \
  -e dispatch52TargetPackage org.levarac.beid.persistenceproof \
  -e class 'org.levarac.beid.persistence.Dispatch52PersistenceInstrumentationTest#<METHOD>' \
  org.levarac.beid.persistenceproof.test/androidx.test.runner.AndroidJUnitRunner
```

Use `seedProductionOwnerKeyAndUnsentLedger`, then
`finishProductionActivityNormally`, then
`verifyProductionOwnerKeyAndUnsentLedgerAfterColdStart`. The seed may be
run again: every invocation creates a unique window and retains earlier
artifacts. Verify that artifact count grows and earlier file hashes remain
unchanged. The fixture checks baseline persistence, target UID, a single
selected phase, and a different verification process PID.

Record Activity close, process identity/disappearance and subsequent startup
separately; a fresh instrumentation PID alone is not proof of a normal app
exit. If package-scoped force-stop is used to ensure process death after
Activity close, disclose it as that extra step, not a natural process exit.
Require `OK (1 test)` in each raw runner result and reject failure/crash/zero
test output even when adb itself exits zero.

Do not run `tools/dispatch52-persistence.sh` on a physical device: it is an
emulator-only workflow that changes network settings and reboots the device.
Physical device reboot requires its own operator-approved step and changed
boot ID evidence. Without that, report normal-close/cold-relaunch only.

These results describe fresh isolated identity/storage using production code.
They do not restore a missing Keystore key in an existing installation, prove
existing-record continuity, cover iOS or RF, or close dispatch#52 by themselves.
