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

## WalletConnect Link Mode spike (2026-07-12, `spike/walletconnect-linkmode`)

**Status: informational only, not merged.** This branch is a source-investigation
spike (same discipline as `spike/walletconnect-native`, which fed into the real
WalletConnect integration above) answering one question left open by GPT-Pro
deep research (kura journal
`2026-07-12-levarac-walletconnect-relay-decentralization.md`, "学び3"): does
reown-swift 2.3.0 have a production-usable, non-deprecated way to run
WalletConnect **without ever touching the Reown relay**, for a wallet on the
same device reachable via Universal Links ("Link Mode")? Answered by reading
reown-swift 2.3.0 source directly (checked out at
`SourcePackages/checkouts/reown-swift`, tag `2.3.0`,
commit `e2e42a0`), not by more doc-reading — no Link Mode section exists in
that repo's own docs (`find ... -iname '*.md' | xargs grep -l 'link mode'`
returns nothing), which is itself evidence the gap GPT-Pro flagged is real.

### Verdict: no, not on the recommended API path. Only the deprecated path can start one.

- `SignClient.connect(namespaces:sessionProperties:scopedProperties:authentication:)`
  — the **non-deprecated, currently-recommended** entry point
  (`Sources/WalletConnectSign/Sign/SignClient.swift:288-308`) —
  unconditionally calls `pairingClient.create()` (an irn/relay Pairing) and
  then `appProposeService.propose(..., relay: RelayProtocolOptions(protocol:
  "irn", ...), authentication: authentication)`. Tracing `authentication`
  into `AppProposeService.propose` (`Services/App/AppProposeService.swift:24-74`)
  shows it only gets turned into `AuthPayload`s embedded *inside* the relay
  proposal (`requests: ProposalRequests(authentication: authPayloads)`) — it
  never switches transport. **`connect()` always creates a relay Pairing,
  regardless of the `authentication` argument.** This is a straight read of
  the source, not an inference from behavior.
- The only method that can start a *new* session without ever creating a
  relay Pairing is `authenticate(_:walletUniversalLink:)`
  (`SignClient.swift:341-347`) — which is marked
  `@available(*, deprecated, message: "Use connect(namespaces:...
  authentication:) ... instead.")`. It delegates to
  `AuthenticateTransportTypeSwitcher.authenticate`
  (`Auth/Services/App/AuthenticateTransportTypeSwitcher.swift`), which tries
  `LinkAuthRequester.request` first and only falls back to the relay
  `pairingClient.create()` path if that throws
  `walletLinkSupportNotProven`. So the deprecated method *is* the real
  relay-less entry point — the recommended replacement's doc comment points
  at an API that cannot do what Link Mode needs.
- There are three purpose-built Link Mode methods —
  `authenticateLinkMode(_:walletUniversalLink:)`, `requestLinkMode(params:)`,
  `respondLinkMode(topic:requestId:response:)` (`SignClient.swift:350-357,
  452-457, 467-473) — but all three are wrapped in `#if DEBUG`. **They do not
  exist in a Release/App Store build.** They appear to be test-only hooks for
  reown's own unit tests to introspect the raw envelope, not a public
  integration surface.
- Good news once a session *is* on Link Mode: ordinary, non-deprecated,
  non-DEBUG-gated `request(params:)` / `respond(topic:requestId:response:)`
  correctly stay off the relay. `SessionRequestDispatcher.request`
  (`LinkAndRelayDispatchers/SessionRequestDispatcher.swift`) switches on
  `session.transportType` (`.relay` vs `.linkMode`,
  `Types/Session/WCSession.swift:4-6`) and calls `linkSessionRequester`
  instead of `relaySessionRequester` when the session was established as
  `.linkMode`. So the gap is specifically in **session establishment**, not
  in-session traffic.

### How "wallet support proven" actually works (no static list, no discovery call)

`walletLinkSupportNotProven` (`Auth/Link/LinkAuthRequester.swift:7,37`) fires
whenever `linkModeLinksStore.get(key: walletUniversalLink) == nil` — a local,
persisted `CodableStore<Bool>` keyed by the wallet's universal link
(`Sign/SignClientFactory.swift:112`). There is no static capability list and
no separate discovery/probe call. The store is only populated after a
**successful relay round-trip**: in
`Auth/Services/App/AuthResponseSubscriber.swift:127-140`
(`getTransportTypeUpgradeIfPossible`), when a relay-based `authenticate`
response comes back, the dApp inspects the *wallet's own*
`AppMetadata.Redirect` in that response (`peerMetadata.redirect.linkMode ==
true` and a `peerRedirect.universal` link present) — if so, and only if the
dApp's *own* metadata also declares `linkMode: true`
(`supportLinkMode = metadata.redirect?.linkMode ?? false`,
`SignClientFactory.swift:114`), it writes `linkModeLinksStore.set(true,
forKey: universalLink)` and upgrades the newly-created session's
`transportType` to `.linkMode` on the spot. Practically: **the first
`authenticate()` call to any given wallet always goes over relay**; only the
*second and later* calls to that same wallet's universal link, using the
deprecated `authenticate(_:walletUniversalLink:)` API, can skip relay
entirely (no Pairing created at all). This proof is symmetric — both sides
must declare `linkMode: true` with a valid `universal` redirect in their
`AppMetadata`, which beid does not do today (`ReownWalletConnectClient.swift:60`
passes `AppMetadata.Redirect(native: "beid://", universal: nil)`, i.e.
`linkMode` defaults to `false`).

### What beid would need to add (not wired up in this spike)

1. A real `https://` Universal Link domain for beid (e.g.
   `https://beid.app` or a subdomain), with an
   `apple-app-site-association` file hosted at
   `https://<domain>/.well-known/apple-app-site-association` (no file
   extension, served as `application/json`, no redirects) declaring beid's
   Team ID + Bundle ID under `applinks`, restricted to paths WalletConnect
   will use for its envelope callback (reown's own code appends
   `?wc_ev=...&topic=...` query params, so a permissive path component
   whose only job is being redirected into `dispatchEnvelope(_:)` is
   enough — see `Auth/Link/LinkEnvelopesDispatcher.swift:145-160` for the
   exact query-param shape it builds and expects back).
2. `com.apple.developer.associated-domains` entitlement with
   `applinks:<domain>` added to `Beid.entitlements` /
   `project.yml` (alongside the existing App Group entitlement) — this
   needs a real Apple Developer Team (associated domains are not usable
   with ad-hoc "Sign to Run Locally" signing, unlike the App Group
   entitlement which the earlier spike found *was* enough on Simulator).
3. `AppMetadata.Redirect(native: "beid://", universal: "https://<domain>/...",
   linkMode: true)` in `ReownWalletConnectClient.swift`, replacing the
   current `universal: nil`.
4. A `NSUserActivity`/`onOpenURL` handler in `BeidApp.swift` (or
   `AppCoordinator`) that recognizes the incoming Universal Link and calls
   `Sign.instance.dispatchEnvelope(_:)` with the full URL string.
5. Switching the pairing call site from `connect(namespaces:...)` (current,
   relay-only per above) to the deprecated
   `authenticate(_:walletUniversalLink:)` — meaning beid would knowingly
   depend on a deprecated reown-swift API to get any relay-less behavior at
   all, with no non-deprecated substitute available in 2.3.0.

### Step 3 (live prototype against a real wallet): skipped, not blocked

No wallet app is installed on any available Simulator
(`xcrun simctl list apps` — none match wallet/MetaMask/Rainbow/Trust), and
Link Mode is fundamentally a same-physical-device Universal Link handoff
between two real native apps — the DemoEvent-style simulator workaround this
repo uses for BLE has no equivalent for Link Mode. This spike had no physical
device with a wallet app installed available to it, and device-lab (`emi`) is
scoped to BLE/two-device proximity testing, not WalletConnect. Noted per the
task brief's "does not need to be blocked on" allowance — the source
investigation above is the deliverable, not a live pairing screenshot.

### Recommendation: drop it, don't pursue further right now

- The only working relay-less path requires depending on a method reown-swift
  has explicitly deprecated with a doc comment that misdirects to an API
  that cannot do what's being asked of it — that is a maintenance liability,
  not a stable integration surface. There is no signal reown-swift will keep
  the deprecated method around, and the DEBUG-gating of the "real" Link Mode
  methods (`authenticateLinkMode` etc.) reads as those APIs still being
  pre-release/unstable internally, not a documentation gap that will
  resolve soon.
- Even if pursued, Link Mode only ever applies to wallets on the *same
  physical device* that have separately proven support via a prior relay
  round-trip — it can never replace relay for cross-device pairing (the
  common case: scan a QR code with a phone, approve on that same phone
  where the wallet app lives, which is same-device — but *also* the desktop
  dApp / mobile wallet cross-device case that WalletConnect exists for in
  the first place). So even a full implementation only removes relay
  dependency for a subset of same-device sessions, never eliminates it.
- beid's own design already treats WalletConnect as optional and
  non-critical-path (`AGENTS.md` — the underlying attendance proof is BLE +
  local signing; see also kura "学び5" — proof-signing is being split out
  into its own state machine on `feat/proof-signing` independent of
  WalletConnect). Given that, spending an Apple-Developer-Team-gated
  Associated Domains + AASA hosting setup to shave relay dependency off a
  same-device subset of an already-optional feature is not worth it at
  beid's current stage.
- Re-evaluate if: reown-swift ships a non-deprecated Link Mode entry point
  (watch reown-swift release notes past 2.3.0), or wallet-signing becomes a
  hard requirement rather than optional (see kura doc's "再検討すべき条件"
  — same trigger list the relay self-host question uses applies here).

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
