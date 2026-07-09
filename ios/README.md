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

- **Wallet**: `WalletConnectStub` returns a fake `0x...` address. No real
  WalletConnect SDK, no signing with an actual wallet key.
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
  Vendor/Barnard/           # vendored SwiftPM package, see above
  Beid/
    App/                    # @main entry point, Info.plist
    Models/                 # Proof, OnboardingMode, DemoEvent
    Persistence/            # ProofStore (JSON)
    Sensing/                # SensingCoordinator, ScanPhase, BluetoothMonitor
    Onboarding/              # WalletConnectStub
    Navigation/              # AppCoordinator, AppScreen, RootView
    Views/                   # all 13 screens
  BeidTests/
    SensingCoordinatorTests.swift
    ProofStoreTests.swift
    OnboardingFlagTests.swift
```
