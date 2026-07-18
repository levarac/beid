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
remote SwiftPM git dependency. The exact upstream commit is recorded in
[`Vendor/Barnard/.pin`](Vendor/Barnard/.pin), the canonical machine-readable
pin.

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

**What we did instead**: copied `packages/swift/barnard` verbatim from the
commit in `Vendor/Barnard/.pin` into `ios/Vendor/Barnard`, referenced via a
local SwiftPM `path` dependency in `project.yml`. This mirrors the pattern the
barnard repo itself already uses (its Swift package is documented as a
mirror, not a move, of the Flutter plugin's Flutter-free sources, with a
`check-swift-mirror.sh` script to catch drift) — vendoring with a pinned SHA
and a drift guard is an accepted convention in this ecosystem, not a one-off
hack.

Run the guard from the repository root whenever the vendored package or pin
changes:

```sh
ios/scripts/check-barnard-vendor.sh
```

It shallow-fetches the commit in `Vendor/Barnard/.pin`, compares upstream's
`packages/swift/barnard` with the local package, and fails on source drift or
if this README or `project.yml` stops referring to the canonical pin. The
`Barnard vendor drift` GitHub Actions workflow runs the guard and its offline
regression tests on pull requests and `main` pushes that touch
`ios/Vendor/**` or the guard's contract files.

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

The wallet step uses the real WalletConnect (Reown) pairing flow — see
"WalletConnect" below.

## WalletConnect

`WalletConnectView` (onboarding) and the Account sheet's "Connect Wallet"
action both use `WalletConnectPairingView`
(`Beid/Views/WalletConnectView.swift`), backed by
`ReownWalletConnectClient` (`Beid/Onboarding/`), which wraps reown-swift
2.3.0's `Sign`/`Pair`/`Networking` APIs directly.

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

**App Group requirement**: `Networking.configure(groupIdentifier:)`
requires a syntactically valid App Group ID (`group.<id>` format) —
`project.yml` wires `Beid/App/Beid.entitlements` with
`group.org.levarac.beid` and the matching
`com.apple.security.application-groups` entitlement. Empirically this is
enough to not crash on Simulator with ad-hoc "Sign to Run Locally" signing
— no real Apple Developer Team was needed for that part (discovered by
`spike/walletconnect-native`, commit `a22d0f4`). A real device build,
under a real team's provisioning, may enforce this more strictly; not
verified here.

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

## DemoEvent mode

The simulator has no BLE radio, so Debug builds force
`SensingCoordinator.useDemoEventMode` on there. Debug builds can also
override the flag for tests and controlled demo walkthroughs. It drives the
same `ScanPhase` state machine a real detection would, without touching
`BarnardEngine`'s scan/advertise calls:

`05 Sensing → 06a Event Found → 06b Verifying (peer count ramps to
totalPeersToVerify) → 06c Verified → 07 Proof Collected → back to 04 home`,
and the new proof lands in `ProofStore`.

Release configurations, including TestFlight and App Store archives, always
report `useDemoEventMode == false` and ignore attempts to enable it. A future
App Review walkthrough in a shipping build therefore needs its own deliberate,
reviewed release mechanism. Walkthroughs run from Debug builds, including on
the Simulator, remain available without letting fabricated proof data enter
the shipping sensing path.

When demo mode is off — including in every Release build — `startSensing()`
instead calls `BarnardEngine.requestPermissions` → `configure(eventCode:)` →
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

- **Wallet**: real WalletConnect (Reown) pairing is wired (see
  "WalletConnect" above), but no real pairing has been completed end-to-end
  — that needs Ken's Reown Cloud Project ID plus a second device running a
  wallet app. No signing with an actual wallet key anywhere in this slice
  (WalletConnect connects an address; it doesn't sign proofs yet).
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
  Secrets.example.plist    # WalletConnect credential template, see above
  Vendor/Barnard/           # vendored SwiftPM package, see above
  Beid/
    App/                    # @main entry point, Info.plist, Beid.entitlements
    Models/                 # Proof, OnboardingMode, DemoEvent
    Persistence/            # ProofStore (JSON)
    Sensing/                # SensingCoordinator, ScanPhase, BluetoothMonitor
    Onboarding/              # WalletConnect (Reown) client + adapters, see above
    Navigation/              # AppCoordinator, AppScreen, RootView
    Views/                   # all 13 screens
  BeidTests/
    SensingCoordinatorTests.swift
    ProofStoreTests.swift
    OnboardingFlagTests.swift
    WalletConnectTests.swift
```
