# beid — native iOS (first slice)

First slice of the native (Flutter-free) beid iOS app. SwiftUI, XcodeGen,
consumes the [levarac/barnard](https://github.com/levarac/barnard) BLE SDK.

## Build & run

```sh
brew install xcodegen   # if you don't have it
cd ios
xcodegen generate
open Beid.xcodeproj
```

Or from the CLI:

```sh
xcodebuild -project ios/Beid.xcodeproj -scheme Beid \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

xcodebuild -project ios/Beid.xcodeproj -scheme Beid \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

Deployment target is iOS 17.0 (bumped from the barnard example's 16.0 —
`navigationDestination(item:)` for the item-detail push requires it).

## Barnard SDK dependency

`project.yml` vendors the SDK locally at `Vendor/Barnard` rather than using a
remote SwiftPM git dependency, pinned to
`levarac/barnard@54385d2fc36e13b436b9fb49691f14a21e17dd5e`.

**Why not a remote git dependency** (the task brief's preferred default):
levarac/barnard's Swift package lives at `packages/swift/barnard`, not at the
repo root, and SwiftPM's remote git dependencies require `Package.swift` at
the dependency repo's root. Pointing `packages.Barnard.url` at
`https://github.com/levarac/barnard` fails to resolve
(`the package manifest at '/Package.swift' cannot be accessed`). A remote-URL
dependency with a subdirectory `path` isn't supported by SwiftPM today, so a
straight remote dependency on the pinned SHA isn't possible without a
companion package-registry entry or a root-level `Package.swift` on barnard's
side (out of scope for this slice).

**What we did instead**: copied `packages/swift/barnard` verbatim from
`levarac/barnard@54385d2` into `ios/Vendor/Barnard`, referenced via a local
SwiftPM `path` dependency in `project.yml`. This mirrors the pattern the
barnard repo itself already uses (its Swift package is documented as a
mirror, not a move, of the Flutter plugin's Flutter-free sources, with a
`check-swift-mirror.sh` script to catch drift) — vendoring with a pinned SHA
and a drift note is an accepted convention in this ecosystem, not a one-off
hack.

**Follow-up**: once barnard publishes the Swift package via a proper
mechanism (root-level `Package.swift`, package registry entry, or a
dedicated release tag/repo), switch `project.yml` back to a real remote
dependency and delete `Vendor/Barnard`.

## WalletConnect (spike)

`spike/walletconnect-native` branch only — not merged to main. Adds a real
WalletConnect (Reown) pairing implementation alongside `WalletConnectStub`,
switchable via a flag, same pattern as `OnboardingMode`:

```swift
// Beid/Onboarding/WalletConnectMode.swift
static let current: WalletConnectMode = .reown  // or .stub
```

- `.stub`: unchanged original behavior — `WalletConnectView` shows the fake
  "Connect Wallet" button, `WalletConnectStub.fakeConnect()` returns a random
  `0x...` address instantly.
- `.reown`: `WalletConnectView` shows `ReownWalletConnectView` — a real
  pairing UI (QR code + copyable URI + live status) backed by
  `ReownWalletConnectClient`, which wraps reown-swift's `Sign`/`Pair`/
  `Networking` APIs.

**SDK choice**: [reown-swift](https://github.com/reown-com/reown-swift)
(actively maintained, latest tag 2.3.0 as of 2026-06-17). The legacy
[WalletConnect/WalletConnectSwiftV2](https://github.com/WalletConnect/WalletConnectSwiftV2)
repo is archived (last push 2024-09-27) — reown-swift is its successor after
the WalletConnect → Reown rebrand. `project.yml` pins the `WalletConnect`
product (→ `WalletConnectSign` target) only, not `ReownAppKit` — AppKit adds
`ReownAppKitUI`/`CoinbaseWalletSDK`/`Yttrium`-adjacent surface area (wallet
picker UI, account abstraction, on-ramp) that doesn't fit beid's "WalletConnect
login, no account abstraction" ruling; both `Networking.configure` and
`Sign.configure` are equally required either way, so AppKit wouldn't have
saved any of the plumbing below. Package platform minimum is iOS 13 —
no deployment-target change needed. Built against the iOS 26 SDK (Xcode 27).

**What had to be hand-rolled** (reown-swift doesn't bundle these):
- A `WebSocketFactory`/`WebSocketConnecting` adapter for the relay transport
  — reown's own example app uses Starscream (last release 2024-03, stale).
  `Beid/Onboarding/NativeWebSocketFactory.swift` implements the same ~8-method
  protocol on native `URLSessionWebSocketTask` instead, avoiding a third
  dependency.
- A `CryptoProvider` (`Beid/Onboarding/NativeCryptoProvider.swift`) — only
  exercised by SIWE (`Sign.instance.authenticate`), which this spike's plain
  `connect(namespaces:)` pairing flow never calls. Left as `fatalError` rather
  than pulling in Web3/CryptoSwift/HDWalletKit (as reown's example app does)
  to satisfy a code path this spike doesn't use.
- QR rendering (`Beid/Onboarding/QRCodeRenderer.swift`) via CoreImage's
  built-in `CIFilter.qrCodeGenerator()` — no third-party QR dependency.

**Credentials required to actually pair**: a Reown Cloud **Project ID**
(free signup at [dashboard.reown.com](https://dashboard.reown.com/) → create
project → copy Project ID). Read from the gitignored `Beid/Secrets.plist`
(`WalletConnectSecrets.projectId`, key `PROJECT_ID`) — copy
`ios/Secrets.example.plist` to `ios/Beid/Secrets.plist` and fill it in.
Without it, `ReownWalletConnectView` shows a "WalletConnect not configured"
state rather than crashing, and the app still builds/tests/runs.

**A second, non-obvious prerequisite**: `Networking.configure(groupIdentifier:)`
requires a syntactically valid App Group ID (`group.<id>` format) — passing
the bare bundle ID crashes at runtime (`WalletConnectRelay/RelayClientFactory.swift:17:
Fatal error: Could not instantiate UserDefaults for a group identifier
org.levarac.beid`). Fixed by using `group.org.levarac.beid` plus a
`com.apple.security.application-groups` entitlement in `project.yml`.
Empirically this is enough to *not crash* on Simulator with ad-hoc
"Sign to Run Locally" signing (`DEVELOPMENT_TEAM: ""`) — no real Apple
Developer Team was needed for that part. A real device build, under a real
team's provisioning, may enforce this more strictly; not verified here.

**Verified on Simulator** (placeholder, non-functional `PROJECT_ID`): the
real `Sign.instance.connect(namespaces:)` call runs, attempts the relay
WebSocket connection, and fails cleanly with "Web socket is not connected to
any URL or networking connection error" — no crash. This is the expected
shape of the projectId-gated boundary; a real Project ID is needed to get
further (generate a live pairing URI, see a wallet actually approve it).

**Not implemented in this spike**: SIWE / `authenticate()`, the
`beid://` redirect round-trip back from a wallet app (nothing to redirect
from in Simulator), disconnect/session-persistence across launches, and
wiring the real flow into `AccountSheetView`'s guest-first "Connect Wallet"
(still stub-only, out of this spike's scope).

## Onboarding flag

Team ruling is WalletConnect-first (no account abstraction), but an
App-Store-risk review recommended guest-first. That product decision is
unresolved, so both orders are implemented behind a single flag:

```swift
// Beid/Models/OnboardingMode.swift
static let current: OnboardingMode = .walletFirst  // or .guestFirst
```

- `.walletFirst`: Welcome → Connect Wallet (stub) → Bluetooth permission → home.
- `.guestFirst`: Welcome → Bluetooth permission → home, with wallet connect
  deferred to the Account sheet.

Flip the flag and rebuild to demo the other order — `OnboardingFlagTests`
exercises both branches (the inapplicable one self-skips via `XCTSkip`
rather than being commented out, so both stay compiled and typo-checked).

The wallet step itself is a stub (`WalletConnectStub.fakeConnect()`) — no
real WalletConnect SDK in this slice, per brief.

## DemoEvent mode

The simulator has no BLE radio, so `SensingCoordinator.useDemoEventMode` is
forced on under `#if targetEnvironment(simulator)`. It drives the same
`ScanPhase` state machine a real detection would, without touching
`BarnardEngine`'s scan/advertise calls:

`05 Sensing → 06a Event Found → 06b Verifying (peer count ramps to
totalPeersToVerify) → 06c Verified → 07 Proof Collected → back to 04 home`,
and the new proof lands in `ProofStore`.

This doubles as the intended future App Review demo mode — a reviewer on a
device with no other beid devices nearby still sees the full flow.

On a real device (`!targetEnvironment(simulator)`), `startSensing()` instead
calls `BarnardEngine.requestPermissions` → `configure(eventCode:)` →
`startAuto()`, and a `BarnardIdentity` per-event signing key is derived via
`signingPublicKey(eventCode:)`. Real BLE detections currently just transition
`.sensing → .eventFound` on the first detection (a real verifying/consensus
policy — counting distinct peers, requiring N to agree — is not implemented
in this slice; see "What's stubbed").

The 06d Signal Lost screen isn't on the golden DemoEvent path (which always
completes successfully) but is fully wired — reachable via
`SensingCoordinator.simulateSignalLost()`, exposed as a "Simulate Signal
Lost" button on the Verifying screen while in DemoEvent mode, and covered by
`testSimulateSignalLostOnlyAppliesDuringVerifying`.

## What's stubbed / out of scope for this slice

- **Wallet**: `WalletConnectStub` returns a fake `0x...` address; this is
  still the default on `main`. The `spike/walletconnect-native` branch adds
  a real reown-swift pairing implementation behind a flag — see "WalletConnect
  (spike)" above — but it has no Ken-side credentials configured, so it
  hasn't completed a real pairing, and there's still no signing with an
  actual wallet key anywhere in this slice.
- **Chain**: no on-chain calls anywhere (`BarnardIdentity.proveRpidOwnership`
  is available in the vendored SDK but not called from the app in this
  slice).
- **Server**: no backend calls. Proofs are local-only.
- **Real BLE verification policy**: on-device, `.eventFound` fires on the
  first detection rather than implementing the "N peers verified" consensus
  policy the design implies; the DemoEvent path is what demonstrates the
  intended UX today.
- **Bluetooth-off screen (03)**: implemented and code-reachable
  (`BluetoothMonitor` watches `CBCentralManager.state`), but not exercised
  in the DemoEvent walkthrough since the simulator always reports Bluetooth
  as powered on.

## Local persistence

Proofs persist to a JSON file in the app's Documents directory
(`ProofStore`), not SwiftData. The data model is a single flat, unordered
array with no relationships or migrations yet, so JSON is the simplest thing
that works for this slice — revisit SwiftData once proofs need
querying/relationships beyond "show them all, newest first".

## Screens

01 Welcome, 02 Bluetooth permission guide, 03 Bluetooth-off, 04 Collection
home (+04b empty state), 05 Scan (radar), 06a Event Found, 06b Verifying,
06c Verified, 06d Signal Lost, 07 Proof Collected, 08 Item Detail, 09
Account sheet — plus a Connect Wallet stub screen for the `.walletFirst`
onboarding order (not in the original 9-screen list, added because the
onboarding-flag requirement needs a screen to flip to).

All screens are plain modern SwiftUI with a blue accent, deliberately not
pixel-polished per the brief.

## Project layout

```
ios/
  project.yml              # XcodeGen spec
  README.md                # this file
  Secrets.example.plist    # WalletConnect spike credential template, see above
  Vendor/Barnard/           # vendored SwiftPM package, see above
  Beid/
    App/                    # @main entry point, Info.plist, Beid.entitlements
    Models/                 # Proof, OnboardingMode, DemoEvent
    Persistence/            # ProofStore (JSON)
    Sensing/                # SensingCoordinator, ScanPhase, BluetoothMonitor
    Onboarding/              # WalletConnectStub + WalletConnect (spike) files
    Navigation/              # AppCoordinator, AppScreen, RootView
    Views/                   # all 13 screens + ReownWalletConnectView (spike)
  BeidTests/
    SensingCoordinatorTests.swift
    ProofStoreTests.swift
    OnboardingFlagTests.swift
```
