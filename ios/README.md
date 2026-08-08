# beid — native iOS (first slice)

First slice of the native (Flutter-free) beid iOS app. SwiftUI, XcodeGen,
consumes the [levarac/barnard](https://github.com/levarac/barnard) BLE SDK.

## Build & run

Use the exact XcodeGen release pinned for Xcode Cloud, not Homebrew's
always-latest formula. From the repository root, the following downloads a
session-local copy and uses it to generate the project:

```sh
# Start in the repository root.
XCODEGEN_VERSION="$(cat ios/ci_scripts/XCODEGEN_VERSION)"
XCODEGEN_TMP="$(mktemp -d)"
curl -sSL --retry 5 --retry-all-errors --retry-delay 2 --connect-timeout 30 \
  -o "$XCODEGEN_TMP/xcodegen.zip" \
  "https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"
unzip -q "$XCODEGEN_TMP/xcodegen.zip" -d "$XCODEGEN_TMP"
export PATH="$XCODEGEN_TMP/xcodegen/bin:$PATH"
test "$(xcodegen --version | awk '{print $2}')" = "$XCODEGEN_VERSION"
cd ios
xcodegen generate
open Beid.xcodeproj
cd ..
```

`project.yml` is the source of truth, but `Beid.xcodeproj` is committed for
local-development convenience. Xcode Cloud regenerates it with the version in
`ci_scripts/XCODEGEN_VERSION` and fails if the committed project drifts, so
regenerate and commit `Beid.xcodeproj` whenever `project.yml` changes. Never
hand-edit the generated project.

Or from the CLI:

```sh
# Start in the repository root.
xcrun simctl list devices available

xcodebuild -project ios/Beid.xcodeproj -scheme Beid \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' build

xcodebuild -project ios/Beid.xcodeproj -scheme Beid \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' test
```

Use a concrete UDID from the first command. Several installed simulators can
share a name, so `name=...` is ambiguous on this host. Do not replace the
destination with `generic/platform=iOS Simulator`: a generic destination can
also build x86_64, while one binary dependency currently provides only an
arm64 Simulator slice. If a link error names an architecture that no usable
simulator on the host actually has, check the destination before changing
code or chasing the error's symbol names.

Every Xcode build runs the always-run **Build BeidSharedKit** pre-build phase.
That phase resolves a supported JDK through
`scripts/resolve_kmp_java_home.sh`, enters `android/` (the repository's Gradle
entry point), and invokes `./gradlew :shared:embedSwiftExportForXcode` before
Swift compilation. If no supported JDK is available, expand **Build
BeidSharedKit** in the Xcode build log and read its JDK/Gradle output; changing
Swift code or the generated module will not fix that toolchain failure.

On the current local host, the full `Beid` test action has taken about 27
minutes. For iteration, compile the app and tests once, then rerun a focused
test without rebuilding:

```sh
# Start in the repository root.
xcrun simctl list devices available

xcodebuild -project ios/Beid.xcodeproj -scheme Beid \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  build-for-testing

xcodebuild -project ios/Beid.xcodeproj -scheme Beid \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  '-only-testing:BeidTests/<TestClass>/<testMethod>' \
  test-without-building
```

`build-for-testing` compiles the app and test bundle but does not run tests.
`test-without-building` reuses those exact products, so rerun
`build-for-testing` after changing source. `-only-testing` shortens an
iteration by selecting a suite or method; it is not the final regression gate
for modified production code. Run the full covering suite after the focused
loop.

Deployment target is iOS 17.0 (bumped from the barnard example's 16.0 —
`navigationDestination(item:)` for the item-detail push requires it).

## Barnard SDK dependency

`project.yml` consumes
[`levarac/barnard`](https://github.com/levarac/barnard) as a remote SwiftPM
package pinned to the exact `0.3.0` release. The committed
`Package.resolved` records the release's precise revision for reproducible
builds. Verified 2026-08-07 against `project.yml` and `Package.resolved`.

Historically, beid copied barnard's Swift package into the repository because
barnard did not have a root `Package.swift`, which SwiftPM requires for a
remote git dependency; a commit pin and drift guard kept that copy aligned.
The vendored workaround was retired on 2026-07-24 after barnard added the root
manifest and published the `v0.1.0` tag.

For local barnard development, drag a local `barnard` checkout into Xcode to
create a package override, or temporarily point `project.yml` at a local
`path:` and re-run `xcodegen generate`; do not commit the override.

## Onboarding flag

Resolved 2026-07-26: the default entry flow is event-first (`guestFirst`).
Wallet connect and binding happen after event confirmation, not at Welcome —
see `docs/specs/onboarding-redesign.md`. Both orders remain implemented
behind a single flag so `walletFirst` stays flippable for demos:

```swift
// Beid/Models/OnboardingMode.swift
static let current: OnboardingMode = .guestFirst  // or .walletFirst
```

- `.walletFirst`: Welcome → Connect Wallet → Bluetooth permission → home,
  with manual event-code entry as the wallet-optional secondary path.
- `.guestFirst` (default): Welcome → Bluetooth permission → home, with wallet
  connect deferred to the Account sheet.

Flip the flag and rebuild to demo the other order — `OnboardingFlagTests`
exercises both branches (the inapplicable one self-skips via `XCTSkip`
rather than being commented out, so both stay compiled and typo-checked).

The wallet step uses the real WalletConnect (Reown) pairing flow — see
"WalletConnect" below.

## WalletConnect

`WalletConnectView` (onboarding) and the Account sheet's "Connect Wallet"
action both use `WalletConnectPairingView`
(`Beid/Views/WalletConnectView.swift`). The UI selects a `WalletConnector`:
`ReownWalletConnectClient` wraps reown-swift 2.3.0, while
`CoinbaseWalletConnector` wraps Coinbase's direct app-to-app mobile SDK.
The selected connector is retained by `AppCoordinator`, so proof signing
uses the same session that supplied the connected address.

**SDK choice**: [reown-swift](https://github.com/reown-com/reown-swift)
(actively maintained; the legacy
[WalletConnect/WalletConnectSwiftV2](https://github.com/WalletConnect/WalletConnectSwiftV2)
repo is archived). `project.yml` pins the `WalletConnect` product (→
`WalletConnectSign` target) only, not `ReownAppKit` — AppKit adds
`ReownAppKitUI`/`CoinbaseWalletSDK`/`Yttrium`-adjacent surface area (wallet
picker UI, account abstraction, on-ramp) that doesn't fit beid's
"WalletConnect login, no account abstraction" ruling.

**What had to be hand-rolled** (reown-swift doesn't bundle these):
- A `WebSocketFactory`/`WebSocketConnecting` adapter for the relay
  transport (`Beid/Onboarding/NativeWebSocketFactory.swift`), on native
  `URLSessionWebSocketTask` — reown's own example app uses Starscream
  (stale), avoided here to skip a third dependency.
- A `CryptoProvider` (`Beid/Onboarding/NativeCryptoProvider.swift`) — only
  exercised by SIWE (`Sign.instance.authenticate`), which beid's plain
  `connect(namespaces:)` pairing flow never calls. Left as `fatalError`
  rather than pulling in Web3/CryptoSwift/HDWalletKit for a code path beid
  doesn't use.
- QR rendering (`Beid/Onboarding/QRCodeRenderer.swift`) via CoreImage's
  built-in `CIFilter.qrCodeGenerator()` — no third-party QR dependency.

**Credentials required to actually pair**: a Reown Cloud **Project ID**
(free signup at [dashboard.reown.com](https://dashboard.reown.com/) →
create project → copy Project ID). Read from the gitignored
`Beid/Secrets.plist` (`WalletConnectSecrets.projectId`, key `PROJECT_ID`) —
copy `ios/Secrets.example.plist` to `ios/Beid/Secrets.plist` and fill it
in. Without it, the pairing view shows a "WalletConnect not configured"
state rather than crashing, and the app still builds/tests/runs — this is
the graceful-degradation path exercised by `WalletConnectTests` and the
default state in CI, where no `Secrets.plist` exists.

**App Group requirement — intentionally NOT shipped while Reown is
unconfigured**: `Networking.configure(groupIdentifier:)` requires a
syntactically valid App Group ID (`group.<id>` format), but that call only
runs when `WalletConnectSecrets.projectId` resolves (see
`configureIfNeeded()`), which it never does in CI/TestFlight builds — no
`Secrets.plist` is present there. The app therefore ships **without** the
`com.apple.security.application-groups` entitlement: carrying it breaks
Xcode Cloud's App Store export ("No profiles for 'org.levarac.beid' were
found") unless the App Group is also registered and assigned in the
Developer Portal, which Apple exposes no API for. When Reown actually gets
configured (a real Project ID reaches distributed builds), restore all
three pieces together:

1. Register `group.org.levarac.beid` under Identifiers → App Groups in the
   Developer Portal, and assign it to the `org.levarac.beid` App ID's App
   Groups capability (both are portal-manual; the capability itself is
   already enabled on the App ID).
2. Re-add `Beid/App/Beid.entitlements` with the
   `com.apple.security.application-groups` array containing
   `group.org.levarac.beid`.
3. Re-add the `entitlements:` block under the `Beid` target in
   `project.yml` and run `xcodegen generate`.

This applies to **local development too**: do NOT put a real Project ID in
`Secrets.plist` on a checkout without steps 2-3 — with a projectId present,
`configureIfNeeded()` hands the group ID to the Reown SDK, whose
`UserDefaults(suiteName:)` / keychain-access-group usage can fail (up to
`fatalError` in `NetworkingClientFactory`) on a build that lacks the
entitlement, especially on a real device.

Historical note: with the entitlement present, Simulator ad-hoc "Sign to
Run Locally" signing worked without any portal registration (discovered by
`spike/walletconnect-native`, commit `a22d0f4`) — the failure only appears
at real distribution signing.

**Verified on Simulator** (no `Secrets.plist` present, matching CI): the
pairing UI reaches `.notConfigured` and does not crash — this is the
graceful-degradation boundary. With a real Project ID, `Sign.instance.connect(namespaces:)`
runs, attempts the relay WebSocket connection, and (per the spike's
manual testing with a placeholder, non-functional Project ID) fails
cleanly rather than crashing when the relay is unreachable.

**Not verified in this slice** (needs Ken's real Project ID plus a second
device running a wallet app — same gap the spike flagged): a real pairing
URI actually being scanned/approved by a wallet, the `beid://` redirect
round-trip back from a wallet app, disconnect/session-persistence across
launches, and SIWE/`authenticate()` (out of scope — beid does WalletConnect
login, not SIWE).

### Coinbase Wallet connector

`project.yml` pins `coinbase/wallet-mobile-sdk` exactly at **1.1.2** and
links its `CoinbaseWalletSDK` product directly. It uses the existing `beid`
custom URL scheme with callback `beid://coinbase-wallet`; no API key,
project ID, relay, or `Secrets.plist` change is required. The app declares
the SDK's `cbwallet` and `mwp+1.1` query schemes so it can detect whether
Coinbase Wallet is installed. If it is absent, the connector does not start
a handshake and the UI offers the Coinbase Wallet App Store page instead.

The upstream project is not archived, but tag 1.1.2 dates from 2024-09-10
and the repository's last source push was 2025-06-12. An
[open upstream issue](https://github.com/coinbase/wallet-mobile-sdk/issues/10)
reports that Mobile Wallet Protocol connection requests may not reach the
Base app on 1.1.2; this is a real-device verification risk, not something a
Simulator test can settle. Keep the exact pin until an upgrade is reviewed
against a real Coinbase Wallet pairing and `personal_sign` round trip.

### MetaMask direct-connect spike (DEBUG only)

`project.yml` pins the archived `MetaMask/metamask-ios-sdk` exactly at
**0.8.10**. The connector initializes the SDK only with
`.deeplinking(dappScheme: "beid")`; it does not select the SDK's Socket.IO
communication layer. `beid://mmsdk` callbacks are forwarded from
`BeidApp.onOpenURL`, and `metamask` is declared in
`LSApplicationQueriesSchemes` so the SDK can detect whether MetaMask is
installed.

The connector and every MetaMask UI entry point are wrapped in `#if DEBUG`.
Release builds therefore retain the existing WalletConnect/Coinbase choices
and behavior. This is a time-bounded compatibility spike: the SDK is archived
and carries a non-commercial license, so it is not a production wallet
foundation.

The 0.8.10 package's bundled `Ecies.xcframework` has an arm64 Simulator slice
but no x86_64 Simulator slice. A multi-architecture Simulator build therefore
fails at link time. The required iPhone 17 Pro Debug test builds only its
active arm64 architecture; for other configurations, explicitly build arm64
only or use a physical device for this spike.

`MetaMaskConnector` owns the active account, chain, connection-attempt ID, and
session ID. It deliberately never reads the SDK's `connected` property because
0.8.10 can leave that value true after disconnect. Unit tests cover an absent
MetaMask installation, disconnect cleanup despite stale SDK state, and a late
connect response after cancellation.

**Still requires a physical-device E2E:** install a current MetaMask Mobile
build and a DEBUG beid build, then verify connect → `personal_sign` → automatic
return to beid, including MetaMask and beid cold starts. The Simulator cannot
settle this because it does not provide the installed-wallet round trip.

## DemoEvent mode

The simulator has no BLE radio, so Debug builds force
`SensingCoordinator.useDemoEventMode` on there. Debug builds can also
override the flag for tests and controlled demo walkthroughs. It drives the
same `ScanPhase` state machine a real detection would, without touching
`BarnardEngine`'s scan/advertise calls:

On a real device (DEBUG builds), launch with the `-beid-demo-event`
argument (e.g. `xcrun devicectl device process launch --device '<DEVICE_ID>'
org.levarac.beid -- -beid-demo-event`) to run the scripted demo without a
second BLE device. Caveat: demo proofs persist in the app container
(`Documents/proofs.json`) indistinguishably from real proofs, and the
container survives installing a TestFlight build over the dev build —
delete the app between a demo E2E session and any real-sensing or
TestFlight evaluation.

`05 Sensing → 06a Event Found → 06b Recording`. The proof lands in
`ProofStore` when recording starts. `RecordingView` first shows the
one-time "Proof Collected" entrance ceremony, then the steady event card as
the peer count grows. The demo remains in recording until the user closes
the scan flow, which returns to 04 home.

Release configurations, including TestFlight and App Store archives, always
report `useDemoEventMode == false` and ignore attempts to enable it. A future
App Review walkthrough in a shipping build therefore needs its own deliberate,
reviewed release mechanism. Walkthroughs run from Debug builds, including on
the Simulator, remain available without letting fabricated proof data enter
the shipping sensing path.

When demo mode is off — including in every Release build — `startSensing()`
instead calls `BarnardEngine.requestPermissions` → `configure(eventCode:)` →
`startAuto()`. `SensingCoordinator` holds one `SensingCryptography` facade,
not a `BarnardIdentity`; the production initializer injects
`BarnardSensingCryptography`. When an event is found, the coordinator obtains
the per-event signing public key through `eventSigningPublicKey(eventCode:)`,
whose production adapter forwards to
`BarnardIdentity.signingPublicKey(eventCode:)`. Real BLE detections currently
transition `.sensing → .eventFound` on the first detection, count distinct
**devices**, and move to `.recording` when
`BeidConfig.eventConfirmThreshold` is reached. That threshold is an app-wide
constant today rather than an organizer-provided event setting; see "What's
stubbed".

Devices are counted by `detectedDisplayId`, not by the proximity identifier
the detection also carries. The proximity identifier rotates every ENIN
window by design, so accumulating those across a session counts (device ×
window) pairs — at the 300-second default, one device present for an hour
would read as twelve. `detectedDisplayId` derives from the per-event key and
does not rotate. Within a single window the two are equivalent, so
`WindowReport.peerCount` still counts proximity identifiers (beid#154).

`detectedDisplayId` arrives from a GATT characteristic read that can fail;
Barnard still emits the detection with a null display id. Such an observation
cannot be attributed to a device, so it never enters the device count and is
surfaced separately as `SensingCoordinator.unidentifiedRpidCount`.

**Confirming an event and counting devices are deliberately two different
questions.** `eventConfirmThreshold` decides only whether to *start
recording*; it asserts nothing. The assertions live in the per-window
reports, each of which records exactly who was present together in that
window, independently of how confirmation was reached. That separation is
what makes the gate safe to satisfy two ways:

- **Co-presence** — enough distinct proximity identifiers **within the
  current ENIN window**. Needs no display id, so a total B003 outage cannot
  stop a real event from being recorded. Sound for the same reason
  `WindowReport.peerCount` is: identifiers do not rotate inside a window.
- **Distinct devices** — `devicesVerified` reaching the threshold. Covers
  sparse-but-real settings the first arm alone would decline to record: a
  hallway, a booth, an arrival trickle, where three real devices pass by one
  at a time and never overlap.

Neither arm accumulates: the window set is cleared at every boundary, and the
device count is keyed on the non-rotating display id. **A single lingering
device satisfies neither**, however long it stays — that is the property this
whole change exists to establish.

If every display-id read fails, the session still records, with
`devicesVerified` at 0 and `unidentifiedRpidCount` above 0. The proof then
claims what is actually true — no identified devices, this many unidentified
observations — rather than a single number that would have to invent one of
the two.

Field measurement of the real B003 read success rate attaches to issue #147
and is non-gating for this behavior. `SensingCoordinator` emits `os.Logger`
lines (subsystem `org.levarac.beid`, category `sensing`) when an observation
arrives with no display id and when an event confirms, so a real-device run
is readable in Console.app or a sysdiagnose without a debug build.

The 06d Signal Lost screen isn't on the golden DemoEvent path (which always
completes successfully) but is fully wired — reachable via
`SensingCoordinator.simulateSignalLost()`, exposed as a "Simulate Signal
Lost" button on the Recording screen while in DemoEvent mode, and covered by
`testSimulateSignalLostOnlyAppliesDuringRecording`.

## What's stubbed / out of scope for this slice

- **Wallet**: real WalletConnect (Reown) pairing is wired (see
  "WalletConnect" above), but no real pairing has been completed end-to-end
  — that needs Ken's Reown Cloud Project ID plus a second device running a
  wallet app. Once a wallet is connected, Item Detail's
  `ProofSignatureControlsView` calls `AppCoordinator.signProof(_:)`, which
  builds a `SignaturePayload`, hashes its canonical JSON with
  `signingDigestHex()`, requests `personal_sign` through the selected
  `WalletConnector`, and persists the returned `SignatureRecord` in the
  proof's `signatureState`. This is the **PROVISIONAL local convenience
  signature** defined in `ProofSignature.swift`: it is not the protocol's
  self-proof, does not prove physical attendance by itself, and no backend or
  verifier may depend on its payload. A real-device connect → sign → return
  round trip is still unverified, as described above.
- **Chain**: no on-chain calls anywhere (`BarnardIdentity.proveRpidOwnership`
  is available in the barnard SDK but not called from the app in this
  slice).
- **Server**: no backend calls. Proofs are local-only.
- **Event-specific verification policy**: distinct-device counting and the
  app-wide `BeidConfig.eventConfirmThreshold` gate run on-device, but an
  organizer-provided per-event threshold is not wired yet.
- **Real BLE signal-loss detection**: 06d can be driven by the demo-only
  manual trigger, but the real sensing path does not yet detect a lost signal
  and enter that phase automatically.
- **Bluetooth-off screen (03)**: implemented and code-reachable
  (`BluetoothMonitor` watches `CBCentralManager.state`), but not exercised
  in the DemoEvent walkthrough since the simulator always reports Bluetooth
  as powered on.

## Local persistence

The iOS app currently has five on-disk stores in its Documents directory:

- `proofs.json` — collected `Proof` values (`ProofStore`).
- `window-reports.json` — durable native observations written before a
  window is closed in the shared ledger (`WindowReportStore`).
- `unsent-window-ledger.snapshot` — the shared ledger's exact canonical
  snapshot bytes, written atomically by `UnsentWindowLedgerStore`.
- `binding-records-v2.json` — wallet/event binding records
  (`BindingRecordStore`).
- `self-proofs.json` — owner-key-signed self-proofs (`SelfProofStore`).

These flat files are used instead of SwiftData. The proof model is still a
single unordered array with no relationships or migrations; revisit SwiftData
when queries or relationships grow beyond "show them all, newest first".
The shared ledger owns its state transitions and snapshot format, while native
iOS owns the file location and atomic write. The production
`SensingCoordinator` uses this runtime. Android has a matching native snapshot
store and portable-codec tests, but its production flow is still deferred to
Issue #121.

## Screens

01 Welcome, 02 Bluetooth permission guide, 03 Bluetooth-off, 04 Collection
home (+04b empty state), 05 Scan (radar), 06a Event Found, 06b Recording
(including the one-time "Proof Collected" entrance ceremony), 06d Signal
Lost, 08 Item Detail, 09 Account sheet — plus Connect Wallet and manual Enter
Event Code screens for the `.walletFirst` onboarding order (not in the
original 9-screen list).

All screens use the repository design-system tokens, adaptive layouts, and
current custom artwork documented in `DESIGN.md`; the original blue-accent
scaffold is historical, not a current implementation guide.

## Project layout

```
ios/
  project.yml              # XcodeGen spec
  Beid.xcodeproj/          # generated project, committed for local convenience
  README.md                # this file
  Secrets.example.plist    # WalletConnect credential template, see above
  Beid/
    App/                    # @main entry point, Info.plist, shared-runtime probe
    Assets.xcassets/        # app icon catalog
    DesignSystem.swift      # reusable SwiftUI components
    DesignSystem/           # tokens, adaptive layout, colors, illustrations
    Localizable.xcstrings   # source strings and target-locale translations
    Models/                 # proof, event, onboarding, and signature models
    Persistence/            # proof/window stores and shared-ledger runtime/store
    Sensing/                # SensingCoordinator, SensingCryptography, BLE state
    Onboarding/             # wallet clients and platform adapters, see above
    Navigation/             # AppCoordinator, AppScreen, RootView
    Views/                  # current onboarding, collection, scan, and detail views
  BeidMetaMaskDebug/        # DEBUG-only MetaMask package isolation target
  BeidTests/                # coordinator, persistence/ledger, cryptography, and UI contract tests
  BeidUITests/              # iPad layout UI tests
  ci_scripts/               # Xcode Cloud hooks and pinned XcodeGen version
```
