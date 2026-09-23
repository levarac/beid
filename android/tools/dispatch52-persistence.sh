#!/usr/bin/env bash
set -euo pipefail

# Offline dispatch#52 host orchestration. The two instrumentation invocations
# are deliberately separate from the production app process; this script
# never clears data or reinstalls between phases.
serial=${1:?usage: $0 <emulator-serial> [apk-dir]}
apk_dir=${2:-"$(cd "$(dirname "$0")/../app/build/outputs/apk" && pwd)"}
app=org.levarac.beid
test_runner=org.levarac.beid.test/androidx.test.runner.AndroidJUnitRunner
log_dir=${TMPDIR:-/tmp}/beid52-persistence
mkdir -p "$log_dir"

adb() { command adb -s "$serial" "$@"; }
[[ "$(adb emu avd name 2>/dev/null | tr -d '\r')" == codex-beid52-m1 ]]
[[ "$(adb shell getprop ro.kernel.qemu | tr -d '\r')" == 1 ]]
offline() {
    adb shell svc wifi disable
    adb shell svc data disable
    [[ "$(adb shell settings get global wifi_on | tr -d '\r')" == 0 ]]
    [[ "$(adb shell settings get global mobile_data | tr -d '\r')" == 0 ]]
}
test_phase() {
    local name=$1 method=$2 log="$log_dir/$1.log"
    adb shell am instrument -w -e dispatch52TargetPackage "$app" -e class "org.levarac.beid.persistence.Dispatch52PersistenceInstrumentationTest#$method" "$test_runner" >"$log" 2>&1
    if ! rg -q 'OK \([1-9][0-9]* test' "$log" || rg -q 'FAILURES!!!|Error in |There was [1-9]' "$log"; then
        tail -n 30 "$log" >&2
        return 1
    fi
}

offline
uid_before=$(adb shell dumpsys package "$app" | sed -n 's/.*uid=\([0-9]*\).*/\1/p' | head -n 1)
[[ -n "$uid_before" ]]

test_phase seed seedProductionOwnerKeyAndUnsentLedger
adb shell am start -W -n "$app/.MainActivity" >/dev/null
pid_a=$(adb shell pidof "$app" | tr -d '\r')
[[ -n "$pid_a" ]]
test_phase normal_finish finishProductionActivityNormally
adb shell am force-stop "$app"
adb shell am start -W -n "$app/.MainActivity" >/dev/null
pid_b=$(adb shell pidof "$app" | tr -d '\r')
[[ -n "$pid_b" && "$pid_b" != "$pid_a" ]]
test_phase normal_restart verifyProductionOwnerKeyAndUnsentLedgerAfterColdStart

test_phase reboot_finish finishProductionActivityNormally
adb shell am force-stop "$app"
boot_before=$(adb shell cat /proc/sys/kernel/random/boot_id | tr -d '\r')
adb reboot
adb wait-for-device
until [[ "$(adb shell getprop sys.boot_completed | tr -d '\r')" == 1 ]]; do sleep 5; done
offline
boot_after=$(adb shell cat /proc/sys/kernel/random/boot_id | tr -d '\r')
[[ "$boot_before" != "$boot_after" ]]
uid_after=$(adb shell dumpsys package "$app" | sed -n 's/.*uid=\([0-9]*\).*/\1/p' | head -n 1)
[[ "$uid_after" == "$uid_before" ]]
adb shell am start -W -n "$app/.MainActivity" >/dev/null
pid_c=$(adb shell pidof "$app" | tr -d '\r')
[[ -n "$pid_c" && "$pid_c" != "$pid_b" ]]
test_phase reboot verifyProductionOwnerKeyAndUnsentLedgerAfterColdStart

printf 'dispatch#52 phases passed: normal pid %s->%s, reboot pid %s, boot_id changed, uid %s, wifi/data_off\n' \
    "$pid_a" "$pid_b" "$pid_c" "$uid_after"
