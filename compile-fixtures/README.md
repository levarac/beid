# KMP compile fixtures

These one-shot patches prove that the platform hosts compile against the
current shared API and module name. Apply each patch in a disposable checkout,
run the command below, and require the named diagnostic. Reverse the patch
before continuing.

## Kotlin stale shared import

```sh
patch -p1 < compile-fixtures/stale-kotlin-symbol.patch
cd android
JAVA_HOME="$(../scripts/resolve_kmp_java_home.sh)" \
  ./gradlew :app:compileDebugKotlin --no-daemon --rerun-tasks
```

Expected: compilation fails while resolving the app's explicit shared-module
import, with `Unresolved reference 'RemovedSharedModuleIdentityIssue107'`.

## Swift stale module import

```sh
patch -p1 < compile-fixtures/stale-swift-module.patch
cd ios
xcodegen generate
cd ..
xcodebuild -project ios/Beid.xcodeproj -scheme Beid \
  -destination 'platform=iOS Simulator,id=5638ACA8-5A90-4931-AB47-9F472D95B7E1' \
  build
```

The current local host has only Xcode 27 beta installed, so that is where this
diagnostic was observed. This is a host property, not a project requirement;
stable Xcode in Xcode Cloud is the authority if local beta behavior differs.

Expected on Xcode 27: compilation fails with `Unable to resolve module
dependency: 'BeidShared'` after the always-run Swift Export phase has generated
`BeidSharedKit`. Older Xcode releases may report the equivalent diagnostic as
`no such module 'BeidShared'`.

Recurring CI automation for negative fixtures belongs to Issue 110. These
fixtures remain deliberately one-shot for Issue 107.

## Swift ledger runtime-authority mutation

```sh
patch -p1 < compile-fixtures/removed-swift-ledger-call.patch
cd ios
xcodegen generate
cd ..
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project ios/Beid.xcodeproj -scheme Beid \
  -destination 'platform=iOS Simulator,id=5638ACA8-5A90-4931-AB47-9F472D95B7E1' \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -only-testing:BeidTests/UnsentWindowLedgerRuntimeTests/testSharedReducerOwnsDuplicateCloseForRepeatedNativeInputs \
  test
```

Expected: the test fails because the production runtime no longer forwards a
close input to `BeidSharedKit.report.closeUnsentWindow`; the durable window
remains open and cannot become the single expected submission. Reverse the
patch before continuing. This is a runtime mutation gate, not a stale-symbol
compile gate.
