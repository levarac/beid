# KMP compile fixtures

These one-shot patches prove that the platform hosts compile against the
current shared API and module name. Apply each patch in a disposable checkout,
run the command below, and require the named diagnostic. Reverse the patch
before continuing.

Here, a disposable checkout means a detached worktree created only for these
destructive fixtures. Create it from the repository root and keep the same
shell open so `$repo_root` and `$fixture_dir` remain available. A detached
worktree does not inherit gitignored `android/local.properties`, and every
fixture below either invokes Gradle directly or reaches it through Xcode's
Swift Export build phase. On the host checked for this guide (2026-08-08),
all three beid checkouts had no such file and the successful setup relied on
`ANDROID_HOME`; `ANDROID_SDK_ROOT` was unset. Require one SDK environment
variable that names an existing directory, without printing its value. A
pasted shell block in this guide may report a problem, but it must not end the
reader-owned shell session:

```sh
# Start in the repository root.
repo_root="$(git rev-parse --show-toplevel)"
if { [ -z "${ANDROID_HOME:-}" ] || [ ! -d "$ANDROID_HOME" ]; } && \
   { [ -z "${ANDROID_SDK_ROOT:-}" ] || [ ! -d "$ANDROID_SDK_ROOT" ]; }; then
  echo "Set ANDROID_HOME or ANDROID_SDK_ROOT to an existing SDK directory, then rerun this setup block." >&2
else
  fixture_parent="$(mktemp -d)"
  fixture_dir="$fixture_parent/beid"
  git -C "$repo_root" worktree add --detach "$fixture_dir" HEAD
  cd "$fixture_dir"
fi
```

## Kotlin stale shared import

```sh
cd "$fixture_dir"
patch -p1 < compile-fixtures/stale-kotlin-symbol.patch
cd android
JAVA_HOME="$(../scripts/resolve_kmp_java_home.sh)" \
  ./gradlew :app:compileDebugKotlin --no-daemon --rerun-tasks
cd "$fixture_dir"
patch -R -p1 < compile-fixtures/stale-kotlin-symbol.patch
```

Expected: compilation fails while resolving the app's explicit shared-module
import, with `Unresolved reference 'RemovedSharedModuleIdentityIssue107'`.

## Swift stale module import

```sh
cd "$fixture_dir"
patch -p1 < compile-fixtures/stale-swift-module.patch
xcrun simctl list devices available
xcodebuild -project ios/Beid.xcodeproj -scheme Beid \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  build
patch -R -p1 < compile-fixtures/stale-swift-module.patch
```

The current local host has only Xcode 27 beta installed, so that is where this
diagnostic was observed. This is a host property, not a project requirement;
stable Xcode in Xcode Cloud is the authority if local beta behavior differs.

Expected on Xcode 27: compilation fails with `Unable to resolve module
dependency: 'BeidShared'` after the always-run Swift Export phase has generated
`BeidSharedKit`. Older Xcode releases may report the equivalent diagnostic as
`no such module 'BeidShared'`.

These fixtures are manual PR gates when their shared/native boundary is in
scope; current CI does not run them. Recurring CI automation for negative
fixtures belongs to Issue 110.

## Swift ledger runtime-authority mutation

```sh
cd "$fixture_dir"
patch -p1 < compile-fixtures/removed-swift-ledger-call.patch
xcrun simctl list devices available
xcodebuild -project ios/Beid.xcodeproj -scheme Beid \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -only-testing:BeidTests/UnsentWindowLedgerRuntimeTests/testSharedReducerOwnsDuplicateCloseForRepeatedNativeInputs \
  test
patch -R -p1 < compile-fixtures/removed-swift-ledger-call.patch
```

Expected: the test fails because the production runtime no longer forwards a
close input to `BeidSharedKit.report.closeUnsentWindow`; the durable window
remains open and cannot become the single expected submission. Reverse the
patch before continuing. This is a runtime mutation gate, not a stale-symbol
compile gate.

After every applied patch has been reversed and the fixture checkout is
clean, remove the disposable worktree:

```sh
cd "$repo_root"
git -C "$repo_root" worktree remove "$fixture_dir"
rmdir "$fixture_parent"
```
