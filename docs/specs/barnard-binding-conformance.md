# Spec — Barnard owner-key/binding conformance (gh#88)

Status: **APPROVED.** Per gh#88's 2026-08-03 decision ("beid
準拠前提。Barnard に合わせて修正する" — beid conforms to Barnard, not the
other way around) and this repo's standing "no code before spec approval"
rule, this document required approval by the PM/user before any of it was
implemented. §6 below contained four decisions the PM/user had to resolve
before approval — the rest of the document did not depend on knowing their
answers in advance, but §2.3/§7's sub-slice C did. All four were resolved by
the user on 2026-08-03, matching this document's own recommendations
exactly (see each decision's resolution note in §6).

Author: Worker `a-20260803-078`, for SubPM `a-20260731-027`.
Survey: `docs/redesign-barnard-0.3-survey.md` — used here only as an index
of where to look; every claim in this document was re-verified directly
against `levarac/barnard` v0.3.0 source (cloned read-only to a scratch
location, not touching this repo's git state) and beid's current
`ios/Beid` source, not taken on the survey's word.
Builds on: `docs/specs/scan-slice2-redesign.md` §5.6 (binding interstitial),
§9.1 (owner-key open decision, resolved 2026-07-30 D1: app-generated, no
continuity for v1), §11 (binding-message byte layout left TBD — this spec
is that TBD, now redirected at Barnard's format instead of a beid-native
one); `docs/specs/scan-protocol-model.md` §4 (binding model), §5 (identity
& commitment), §6 (timestamp integrity).
Tracks: gh#88. Barnard is pinned at 0.3.0 (`ios/project.yml`); confirmed
(prior survey, re-confirmed here) that 0.2.0→0.3.0 touched zero owner-key/
binding files, so this work is independent of that pin.

## 1. Scope

**IN**: replacing beid's three hand-rolled types —
`OwnerKeyProvider` (wrong KDF), `BindingMessage` (wrong wallet-signed
content), and the K-countersign step in `SensingCoordinator` (wrong
second signer) — with calls into `BarnardCore.BarnardCoreSigning`'s
owner-key API surface, so a Barnard-conformant verifier (Android/
BarnardCore, or any future server-side verifier) can recognize a beid
binding as a `barnard-account-binding:v1` ceremony. Adds a self-proof
layer beid does not have today at all. Covers: the four
type-to-API mappings (§2), the resulting wallet-prompt UX change (§3), an
explicit out-of-scope boundary (§4), how this must be tested (§5), four
decisions the PM/user must resolve before approval (§6), and acceptance
criteria + sub-slicing (§7).

**OUT** (see §4 for the full list and reasoning): the 2-approval connect
+sign flow shape itself, mutual-sensing threshold-confirm, the
`RecordingView` entrance ceremony / `SignalLostView` pause-resume (already
shipped, Scan Slice-2 2c), the per-window report signing path
(`EventCommitment`/`activeCommit`/`windowReportPayload` — a structurally
separate mechanism, confirmed in §4), and building any unbind UI (§6.c).

**Method note**: no product code was written or edited to produce this
document. Every function signature, byte offset, and test-vector hex
value cited below was read directly from `levarac/barnard` v0.3.0 source
(`specs/092-owner-key/spec.md`, `Sources/BarnardCore/BarnardCoreSigning.swift`,
`Sources/BarnardCore/BarnardCoreOwnerKey.swift`,
`Tests/BarnardCoreTests/BarnardOwnerKeyPrimitiveTests.swift`,
`Tests/BarnardCoreTests/BarnardOwnerKeyMessageTests.swift`) and beid's
current `ios/Beid` source, this session.

## 2. What replaces what

Four independent type-to-API mappings. For each: the precise Barnard call,
and whether beid should call it directly at each call site or wrap it in a
thin beid-side type — with reasoning, not just a pick.

### 2.1 Owner-key derivation: `OwnerKeyProvider` → `BarnardCoreSigning.deriveOwnerKeyPair`

**Today** (`OwnerKeyProvider.swift:60`):
`BarnardCoreSigning.deriveSigningKeyPair(deviceSecret: seed, eventCode: "beid-owner-key:v1")`
— the **event-signing-key** KDF (`info = "barnard-sign"`), fed a fixed
string standing in for `eventCode`.

**Replaces with**: `BarnardCoreSigning.deriveOwnerKeyPair(accountSecret: seed)`
— the dedicated owner-key KDF (`info = "barnard-owner"`,
`BarnardCoreSigning.swift:74-102`). Different `info` tag, different
function, produces an unrelated key pair from the same seed.

One part of today's implementation is **already correct** and does not
change: the 32-byte seed (`OwnerKeyProvider.seedKey =
"beid.ownerKeySeed"`) is already generated and stored independently of
`BarnardIdentity`'s `DeviceSecret` (separate `UserDefaults` key, separate
`BarnardCoreKeyManager.loadOrCreate` call) — this already satisfies the
spec's "`AccountSecret` MUST NOT be derived from `DeviceSecret`" rule
(Key hierarchy section). Only the derivation *function* called on that
seed is wrong.

**Wrap or call directly? Wrap — keep `OwnerKeyProvider` as the single
owner-key gatekeeper, growing two new methods instead of exposing the
private key.** Self-proof (§2.2) and wallet-ack (§2.4) both need to sign
with the *owner private key*, which today never leaves `OwnerKeyProvider`
(only `publicKeyCompressed()` is exposed). Recommend adding:

```swift
extension OwnerKeyProvider {
  func signSelfProof(
    eventIdHash: Data, eventSigningPublicKey: Data,
    eninStart: UInt64, eninEnd: UInt64
  ) -> BarnardCoreRecoverableSignature?

  func signWalletAcknowledgement(
    walletAddress: Data, walletSignature: Data
  ) -> BarnardCoreRecoverableSignature?
}
```

Reasoning:
- **Matches the existing pattern exactly.** `BarnardIdentity.sign(eventCode:bytes:)`
  already hides the event signing private key inside itself and returns
  only a signature — `OwnerKeyProvider` should mirror that, not become the
  one type in the app that hands raw private-key bytes to a caller.
- **Testability.** `OwnerKeyProvider`'s constructor already accepts
  injectable `keyStorage`/`randomSource` — a test can seed a fixed
  `accountSecret` and assert `publicKeyCompressed()` against Barnard's own
  pinned zero-seed vector (§5) without touching real `UserDefaults`.
- **Call-site minimalism.** `SensingCoordinator` already holds one
  `ownerKeyProvider: OwnerKeyProvider` instance; growing its API by two
  methods is a smaller diff than introducing a second owner-key-aware type
  alongside it.

### 2.2 The missing self-proof layer → `buildSelfProofMessage` / `signSelfProof` / `verifySelfProof`

**Today**: nothing. `EventCommitment.compute` is the closest existing
concept but is a structurally different primitive — a plain, unsigned
`SHA256(K ‖ ownerKey ‖ salt)` with **no owner-key signature at all**
(survey §1, re-confirmed: anyone who observes `K`, `ownerKey`, and `salt`
on the wire can recompute the identical hash without controlling any
private key).

**Important, and easy to miss**: self-proof does **not** replace
`EventCommitment`/`activeCommit`/`windowReportPayload`. They serve
different purposes and the spec is explicit about this — self-proofs are
listed under "holder-held artifacts," which "MUST NOT appear in Advertise
data, GATT values, public anchors, or witness blobs" (Security and privacy
section). `activeCommit` is exactly the opposite: an opaque hash placed on
every window report's wire content by design (selective disclosure,
`scan-protocol-model.md` §5). Adopting self-proof does **not** force a
change to the window-report wire format — see §4 for the explicit
confirmation that `windowReportPayload` stays untouched.

**Replaces/adds**: `BarnardCoreSigning.buildSelfProofMessage(eventIdHash:eventSigningPublicKey:eninStart:eninEnd:ownerPublicKey:)`
→ 135-byte message (offsets per spec: domain tag 0-21, `eventIdHash` 21-53,
`K` 53-86, `eninStart` 86-94, `eninEnd` 94-102, owner public key 102-135) →
`signSelfProof(ownerPrivateKey:...)` (owner key signs `SHA256(message)`).
`verifySelfProof` is for a future verifier role, not producer-side; beid
only needs to *build and sign* one today.

**Wrap or call directly? Wrap, inside `OwnerKeyProvider`** — see §2.1's
`signSelfProof` method. Same reasoning (private key stays gatekept in one
type).

**Two real implementation-level TBDs this spec does not resolve** (neither
is one of §6's four blocking decisions — noted here so they aren't
silently lost, matching `scan-slice2-redesign.md` §11's convention for
non-blocking TBDs):

- **`eventIdHash` construction.** Barnard requires a 32-byte digest; beid's
  `eventCode` is a `String` (e.g. `"ETHTOKYO2026"`). Recommend
  `SHA256(UTF8(eventCode))` — the spec does not mandate a specific mapping,
  only that the input is 32 bytes.
- **When to sign, and where to store it.** `eninEnd` cannot be known until
  the event's last ENIN window closes — unlike `activeCommit`, which is
  fixed at `beginEventFound` (§`SensingCoordinator.swift:266-273`),
  self-proof can only be finalized at session end (`stopSensing()`/final
  `closeWindow`), not session start. Recommend a new small local store
  mirroring `BindingRecordStore`'s pattern (flat JSON, on-device only) —
  nothing in beid consumes a self-proof yet (there is no verifier/
  credential-presentation flow in the app, confirmed by grep: no such flow
  exists), so this is forward groundwork, the same posture
  `scan-slice2-redesign.md` §4.5 already took for `WindowReportStore`
  records that are produced but not yet transmitted.

### 2.3 Wallet-binding message: `BindingMessage` → `barnard-account-binding:v1` canonical text

**Today** (`BindingMessage.swift`): a beid-defined schema tag
(`"beid-binding/v1"`) ‖ `eventCode` ‖ `K` (not owner key) ‖ big-endian
`Int64` unix-ms, then `walletDigestHex()` = `"0x" + hex(SHA256(canonicalBytes))`
— a bare 32-byte digest passed as the `personal_sign` message at every
connector call site.

**Replaces with**: `BarnardCoreSigning.buildAccountBindingText(domain:walletAddress:ownerPublicKey:chainId:nonce:issuedAt:)`
— returns the literal 11-line UTF-8 text (not a digest of it):

```text
{domain} wants to bind this wallet to a Levarac owner key.

This signature authorizes no transaction and moves no assets.

Domain-Tag: barnard-account-binding:v1
Wallet: 0x{20-byte wallet address, lowercase hex}
Owner-Key: 0x{33-byte compressed owner public key, lowercase hex}
Chain-ID: eip155:{chainId}
Scope: global
Nonce: 0x{16-byte nonce, lowercase hex}
Issued-At: {RFC 3339 UTC, second precision}
```

**Mechanical consequence that must not be missed**: `personal_sign`'s
"message" parameter must carry the hex encoding of the **UTF-8 text
bytes**, not a hash of them. Every connector call site
(`CoinbaseWalletConnector.swift:191-197`,
`ReownWalletConnectClient.swift:180-183`, and MetaMask's
`sdk.personalSign(message:address:)`) already accepts a `0x`-prefixed hex
string as "message" — the shape of the call doesn't change, only what the
hex decodes to (≈400 raw text bytes instead of 32 digest bytes). The
existing parameter name `digestHex` (`SensingCoordinator.beginBinding()`,
`WalletConnector.requestPersonalSign(digestHex:)`) becomes a misnomer once
it's carrying text bytes rather than a digest — recommend renaming to
`messageHex` at implementation time (not a blocking decision, just a
correctness-adjacent cleanup that should ride along with this change so
the name doesn't lie).

**Wrap or call directly? Wrap, in a small beid-side value type replacing
`BindingMessage`** (same name is fine — its *body* changes, not
necessarily its identity in the codebase), holding `(domain, walletAddress,
ownerPublicKey, chainId, nonce, issuedAt)` and calling
`buildAccountBindingText` internally. Reasoning:
- **Fixed-once-reused-twice, exactly like today.** `SensingCoordinator`
  holds `pendingBindingMessage` across the async round trip so the wallet
  signature and the later wallet-ack (§2.4) provably reference the same
  `nonce`/`issuedAt` — a bare static-function call from two separate call
  sites risks the nonce or timestamp drifting between them. Keeping a
  fixed value type preserves this invariant the same way `BindingMessage`
  already does.
- **Testability**: a beid-side type with injectable fields is what lets a
  unit test hold `domain`/`chainId`/`nonce`/`issuedAt` fixed and assert
  byte-exact equality against Barnard's own pinned golden vector (§5).

### 2.4 Device countersign → owner-key-signed `barnard-wallet-ack:v1`

**Today** (`SensingCoordinator.completeBinding`): `identity.sign(eventCode:bytes:)`
— the **event signing key K** — countersigns the *same* `canonicalBytes`
the wallet just signed.

**Replaces with**: `BarnardCoreSigning.signWalletAcknowledgement(ownerPrivateKey:walletAddress:walletSignature:)`,
which signs `buildWalletAcknowledgementMessage(walletAddress:walletSignature:)`
= `"barnard-wallet-ack:v1"` ‖ `walletAddress`(20) ‖
`SHA256(walletSignatureBytes)` — the **owner key**, referencing the
wallet's *actual signature bytes* (not the pre-signature message). No flow
reordering is needed: `completeBinding(walletAddress:walletSignatureHex:)`
is already called *after* the wallet signs, with the signature already in
hand as a parameter — only the computation inside it changes.

**Wrap or call directly? Wrap, via `OwnerKeyProvider.signWalletAcknowledgement`**
(§2.1) — same reasoning as self-proof: the owner private key never leaves
`OwnerKeyProvider`.

**Minor plumbing note, not a design decision**: `BindingRecord`'s
`deviceSignature` parameter is typed `Barnard.BarnardRecoverableSignature`
(`r`/`s`: `Data`, from the high-level `Barnard` product), while
`BarnardCoreSigning.signWalletAcknowledgement` returns
`BarnardCore.BarnardCoreRecoverableSignature` (`r`/`s`: `[UInt8]`, from the
lower-level `BarnardCore` product `OwnerKeyProvider` already imports). A
one-line bridge (`Data($0)`) at the `completeBinding` call site is all
that's needed — `BindingRecord`'s own field shape
(`deviceSignatureRHex`/`SHex`/`V`) does not change, only which key/message
produced the bytes it stores (relevant to §6.d's migration answer: the
on-disk schema is unchanged, only its cryptographic meaning is).

**Correction (implementation-confirmed):** the one-line bridge above turned
out not to be constructible. `Barnard.BarnardRecoverableSignature`'s
auto-synthesized memberwise initializer is `internal`, not `public` — a
real Swift behavior: a struct's implicit memberwise init is never
automatically `public`, even when the struct itself and all its properties
are — so it cannot be built from raw bytes outside the `Barnard` module the
way `Data($0)` implied. The shipped code instead types
`BindingRecord.deviceSignature` as `BarnardCore.BarnardCoreRecoverableSignature`
directly, which does have a public init and is exactly what
`OwnerKeyProvider.signWalletAcknowledgement` already returns natively — so
no bridge is needed at all, simpler than what this section originally
proposed.

## 3. UX delta at the wallet `personal_sign` step

**What the user currently sees**: today's `digestHex` is `"0x" +
hex(SHA256(...))` — after the wallet un-hexes it, the 32 raw bytes are
not valid UTF-8 text, so wallet apps (MetaMask, Coinbase Wallet, and
WalletConnect-connected wallets generally) cannot render it as readable
text and fall back to showing raw hex/bytes in the signing-confirmation
sheet. This is the same visual shape most wallets treat as a **blind-sign
red flag** — many show an explicit warning banner ("this message can't be
read, sign at your own risk" or similar) for exactly this pattern, because
it's indistinguishable from what a malicious drainer's blind-sign request
also looks like.

**What the user will see under the Barnard-conformant scheme**: the hex
now decodes to the full literal 11-line canonical text (§2.3) — a real
English sentence, explicit non-transaction framing, and labeled fields
(`Wallet`, `Owner-Key`, `Chain-ID`, `Scope`, `Nonce`, `Issued-At`). Most
wallet apps that detect valid UTF-8 inside a `personal_sign` hex payload
render it as plain text, so the user reads the actual statement instead of
opaque hex.

**Concretely, what changes in `EventBindingSheetView.swift`'s flow: nothing
in the view's own code.** `performBinding(address:connector:)` still calls
`sensing.beginBinding()` then `connector.requestPersonalSign(digestHex:)`
and awaits the result exactly as today (`EventBindingSheetView.swift:184-213`)
— the sheet never renders the signing prompt itself; that's entirely
inside the external wallet app's UI, which beid does not control and
cannot see. `isInFlight`/`ProgressView`/the awaiting-approval state are
unchanged. The only thing that changes is the *content* of the string
`beginBinding()` returns, which is invisible to beid's own view code. This
is a more accurate answer than inventing new UI states this change doesn't
actually need.

**Does this make the existing 2-approval flow (connect, then a separate
sign step — 2026-07-31 decision, no connector supports a true 1-round-trip
connect+sign) better or worse?**

**Recommendation: net better**, on balance, though not for free:

- **Better**: Barnard's own spec states the design intent directly — "The
  visible domain and explicit non-transaction statements reduce
  blind-signing risk" (Security and privacy section). Today's opaque hex
  is the exact shape wallet apps flag as suspicious; a readable statement
  with an explicit "authorizes no transaction and moves no assets" line
  should reduce both the warning-banner friction and legitimate user
  hesitation ("what am I signing?") — a real trust improvement, not
  cosmetic.
- **Worse (real, not dismissed)**: the text is long (~400 UTF-8 bytes, 8
  labeled fields across 11 lines) versus a short, if meaningless, hex
  blob — more to read/scroll in a wallet's confirmation sheet, and two
  fields (`Nonce`, `Chain-ID`) are unfamiliar jargon to a non-technical
  user with nothing in beid's own UI to explain them (they're generated/
  supplied entirely by the signing infrastructure, invisible until this
  exact moment). Some mobile wallet `personal_sign` sheets don't expand
  to fit an 11-line message without scrolling, which is a minor added
  interaction cost versus today's compact (if meaningless) blob.
- Net judgment: replacing "opaque hex that looks like a scam" with
  "a longer but genuinely readable, explicitly-non-transactional
  statement" is the right trade for a beid-scale user base signing at
  most once per event — the blind-sign risk this replaces is the more
  serious failure mode of the two.

## 4. What stays out of scope

Explicitly **not** touched by this convergence work, confirmed by reading
the actual current code (not assumed):

- **The 2-approval connect+sign flow shape** (2026-07-31 decision — no
  connector supports 1-round-trip connect+sign). This spec changes what
  gets signed at step 2, not the two-step shape itself.
- **Mutual-sensing threshold-confirm** (`BeidConfig.eventConfirmThreshold`,
  `SensingCoordinator`'s `peersVerified` counting) — untouched; owner-key/
  binding conformance has no dependency on how/when `.recording` begins.
- **`RecordingView`'s entrance-ceremony visuals and `SignalLostView`'s
  pause/resume behavior** (Scan Slice-2 2c, already shipped) — untouched;
  this spec's only UI-adjacent surface is `EventBindingSheetView` (§3), and
  even there the view's own code doesn't change.
- **The per-window report signing path** — `EventCommitment.compute`,
  `SensingCoordinator.activeCommit`, `closeWindow`, and
  `windowReportPayload` (`SensingCoordinator.swift:405-427`) are confirmed
  by direct read to be a **structurally separate mechanism**: they compute
  and sign `eventCode ‖ enin ‖ commit ‖ sorted(peerRpids)` with the *event
  signing key* `identity.sign(eventCode:bytes:)`, never referencing
  `BindingMessage`, `OwnerKeyProvider`'s new signing methods, or anything
  this spec changes. §2.2 already established self-proof does not replace
  `activeCommit` either (different purpose, different disclosure rule).
  This path is untouched by this spec, full stop — no "unless conformance
  forces a change" caveat applies here, because it doesn't.
- **Building any unbind/revoke UI or flow.** See §6.c — this is a
  recommendation with reasoning, not a self-evident exclusion, so it's
  argued properly there rather than asserted here.

## 5. Testability — golden-vector conformance, not self-verification

**The failure mode this section exists to prevent, stated plainly**: a
test that constructs the canonical text/self-proof/wallet-ack bytes using
beid's *own* new implementation and then asserts beid's implementation
produces those same bytes proves nothing about correctness. It only proves
internal consistency. This is exactly the failure mode that let beid's
current (non-conformant) `BindingMessageTests`-style tests pass for months
while the format was never actually Barnard-conformant — self-consistency
is not conformance.

**Requirement**: every new test for §2's four mappings must assert
byte-exactness against **Barnard's own pinned golden vectors** (from its
own test suite, not beid's re-derivation of the same logic). These already
exist and were read directly from `levarac/barnard` v0.3.0:

- **Owner-key derivation** (`BarnardOwnerKeyPrimitiveTests.swift:7-31`,
  `testDeriveOwnerKeyPairMatchesCrossImplementationVectors`):
  `accountSecret` = 32 zero bytes → private key
  `46cbfd04992339fab4937354a6f24c115a238f4bd133a8c43b18162ab986bf27`,
  public key
  `03351e5165d083f53425fc4a51e7228d53e88eb2899bcb6a83368a8aafaa1de5f4`;
  `accountSecret` = bytes `0x00..0x1f` → private key
  `3cfd4805b144d962c1cddccdf8452f02bfe022a867f550b0eb5ed8b2512ec758`,
  public key
  `03879beac8b548009124867a99a358aeb34ff42f957f868bbc83339568b16d9c67`.
  A beid unit test seeds `OwnerKeyProvider`'s injected `keyStorage` with
  the zero-byte seed and asserts `publicKeyCompressed()` equals the first
  hex value above — hardcoding Barnard's own expected output, not
  beid's derivation of it.
- **Canonical binding text** (`BarnardOwnerKeyMessageTests.swift:13-110`,
  `testCanonicalBindingTextMatchesPinnedBytesAndDigest`): for domain
  `beid.levarac.org`, wallet `0x14791697260e4c9a71f18484c9f997b308e59325`,
  owner key
  `03879beac8b548009124867a99a358aeb34ff42f957f868bbc83339568b16d9c67`,
  `chainId` 1, nonce `0x000102030405060708090a0b0c0d0e0f`, `issuedAt`
  `2026-07-30T09:00:00Z`, the pinned output is a byte-exact 407-byte text
  (quoted in full in §2.3 above, same wording) whose EIP-191 digest is
  `1aad6c43694a0e64bf3994959907b7392a590a1e7139bc9f52a86dc71709dc44`. **If
  §6.a resolves to the literal domain `beid.levarac.org`, this input set
  is directly reusable as-is** — a beid conformance test can hardcode
  these exact inputs and assert its own `buildAccountBindingText` call
  (via the new type in §2.3) produces the identical 407-byte text and
  digest Barnard's own suite expects.
- **Self-proof message layout** (`BarnardOwnerKeyMessageTests.swift:169-193`,
  `testSelfProofBuilderSignerAndVerifier`): confirms the exact 135-byte
  offset layout (§2.2) with concrete byte values — usable as a structural
  (not just round-trip) assertion.
- **Wallet acknowledgement message layout**
  (`BarnardOwnerKeyMessageTests.swift:292-317`,
  `testWalletAcknowledgementBuilderSignerAndVerifier`): confirms the exact
  73-byte offset layout (§2.4) with concrete byte values.

**What a real conformance test looks like, concretely**: hardcode one of
the input sets above into a beid `XCTestCase`, call beid's new
implementation (the `OwnerKeyProvider` methods from §2.1/§2.2/§2.4, the
binding-text type from §2.3), and assert the output bytes/hex match
Barnard's pinned expectation exactly — not "assert beid's function is
idempotent with itself," but "assert beid's function produces what
Barnard's own suite, compiled from the exact same pinned package version,
independently expects."

**Local simulator is unusable on this machine** (CoreSimulator symlinked
to an external volume with zero available devices — a known, pre-existing
environment issue, not something this spec's testing strategy should route
around by skipping tests). None of the above tests need a simulator or
device at all — they are pure `BarnardCore`/Foundation unit tests
(`XCTAssertEqual` on byte arrays and hex strings), runnable in any
`xctest` environment. **Xcode Cloud's PR CI (`BeidTests`) is the actual
gate** for confirming they pass, regardless of local simulator
availability — this repo's PR CI already runs `BeidTests`/`BeidUITests` on
Apple's own infra per `AGENTS.md`'s CI contract. No acceptance criterion
in §7 assumes a locally-booted simulator.

## 6. Open decisions (blocking approval)

These four are raised in escalation format — background, options with
real tradeoffs, and a recommendation with reasoning — because the PM is
putting them directly in front of the user, and per gh#88 the spec cannot
be approved without them.

### 6.a Domain field value

**Background**: `{domain}` is the first token of the canonical binding
text and is validated by `BarnardCoreSigning`'s `isCanonicalDomain` (an
already-normalized, lowercase ASCII authority — host, or host+port — no
whitespace/slash/CR/LF; `BarnardCoreOwnerKey.swift:728-781`). Barnard's own
worked example, and its own pinned test vector
(`BarnardOwnerKeyMessageTests.swift:16`), both use the literal
`beid.levarac.org`. gh#88's own prior analysis already flagged that this
example domain and the spec's example `Issued-At`
(`2026-07-30T09:00:00Z`) match beid's own D1 decision date exactly —
circumstantial evidence the spec was authored with beid specifically as
the anticipated reference implementation, since confirmed by the user
(gh#88 comment, 2026-08-03: "beid 準拠前提"). Separately confirmed this
session: **beid has no associated-domains/applinks/webcredentials
entitlement anywhere in `ios/`** (no `.entitlements` file exists in the
repo at all) — `"levarac.org"` today appears only as a metadata `url:`
string handed to the MetaMask/Reown SDKs' own app-identification UI
(`MetaMaskConnector.swift:204`, `ReownWalletConnectClient.swift:67`), not
as a domain beid serves or has proven ownership of via any
Apple/DNS-verifiable mechanism.

**Options**:

- **(a) Emit `beid.levarac.org` literally**, matching Barnard's own worked
  example and pinned test vector exactly.
  - *For*: strong circumstantial + now-confirmed evidence the spec
    anticipates exactly this value; nothing in the spec's normative rules
    requires DNS resolution or ownership proof — the domain is
    syntactic/label-level only ("Barnard emits the validated value exactly
    as supplied," host responsibility, out of Barnard's own scope per its
    Non-goals: "Key generation entropy, secret custody, backup, migration,
    wallet transport, and user-interface flows remain host
    responsibilities"); lets a conformance test (§5) reuse Barnard's exact
    pinned golden vector input-for-input, a real and immediate testability
    win.
  - *Against*: if `beid.levarac.org` does not currently resolve to
    anything, a technically curious signing user who checks the domain in
    a browser finds a dead host — not deceptive under the spec's own
    rules (the field is a label, not a fetched URL), but a minor
    legitimacy signal gap for a ceremony whose whole point is
    trust-building (§3).
- **(b) Stand up a real, beid-controlled `beid.levarac.org`** (DNS record
  + minimal hosted content, possibly an iOS Associated Domains
  entitlement) before emitting it in the signing ceremony.
  - *For*: closes the "does it need to resolve" question permanently;
    matches how production EIP-4361/SIWE-style domain-binding schemes
    typically expect the domain to be real and checkable.
  - *Against*: pulls in real infrastructure work (DNS + hosting, possibly
    entitlements) entirely outside this app repo's control and outside
    what a spec-then-code app-layer slice should block on — makes this
    spec depend on whoever owns `levarac.org` DNS, which is not resolvable
    inside this convergence work's scope.

**Recommendation: (a)**, emit `beid.levarac.org` literally now, and
**separately** (not blocking this spec or its sub-slices) flag to whoever
owns `levarac.org` DNS that a real, even minimal, `beid.levarac.org` host
should exist so the label isn't a dead end for a curious user — an
infra/marketing follow-up, not implementation work this spec's sub-slices
need to include.

**RESOLVED (user, 2026-08-03)**: option (a) — emit `beid.levarac.org`
literally, matching this section's recommendation exactly. Standing up a
real, beid-controlled host at that domain is a non-blocking infra
follow-up, not part of any implementation sub-slice.

### 6.b Chain-ID

**Background**: the canonical text requires `Chain-ID: eip155:{chainId}`,
an unsigned 64-bit decimal. Read all three connectors
(`CoinbaseWalletConnector.swift`, `MetaMaskConnector.swift`,
`ReownWalletConnectClient.swift`) and the shared `WalletConnector`
protocol directly, rather than assuming.

**Findings**:

- `WalletConnector` (the shared protocol, `WalletConnector.swift:34`)
  already requires `var chainId: String { get }` on every conformer —
  non-optional, always available once queried.
- **`CoinbaseWalletConnector`**: `chainId` resolves to
  `account?.chainId ?? "eip155:1"`; `account.chainId` is set at
  `initiateHandshake`'s completion (`"eip155:\(account.networkId)"`,
  `CoinbaseWalletConnector.swift:180-183`) — the **same callback** that
  delivers `address`. Chain ID and address become known in the identical
  instant, both *before* any subsequent `personal_sign` call.
  `networkId` is wallet-reported (whatever chain the user's Coinbase
  Wallet is actually active on) — not fixed by beid's request.
- **`MetaMaskConnector`**: **the entire file is wrapped in `#if DEBUG`**
  — this connector does not exist in Release builds at all. Worth stating
  plainly since the task framing assumed three equally-shipping
  connectors; only Coinbase and Reown ship to real users, MetaMask is a
  DEBUG-only dev aid (`ios/README.md`'s convention, consistent with the
  file-level guard). Within DEBUG, `chainId` resolves the same way as
  Coinbase — set at `connect()`'s result, same moment as `address`
  (`MetaMaskConnector.swift:212-221`, `caip2ChainId(sdk.chainId)`).
- **`ReownWalletConnectClient`**: `chainId` resolves from
  `connectedSession?.namespaces["eip155"]?.accounts.first?.blockchainIdentifier
  ?? "eip155:1"`, set when `sessionSettlePublisher` fires
  (`ReownWalletConnectClient.swift:137-153`) — again, the same instant
  `state` becomes `.connected(address:)`, before any sign step. **But**:
  `connect()`'s own proposal hardcodes `chains: [Blockchain("eip155:1")!]`
  (`ReownWalletConnectClient.swift:93-99`) — Reown's connect flow only
  ever *requests* chain 1, so its reported `chainId` reflects what beid
  asked for, not necessarily an independently wallet-reported value the
  way Coinbase's does. Not a blocker (the value is still known before
  signing), but a real asymmetry between connectors worth a one-line
  implementation note so a future reader doesn't assume both are equally
  "real."

**Conclusion, stated plainly**: **a reliable chain ID is available before
the user is asked to sign the binding text, for every connector that
exists in beid today** (Release: Coinbase + Reown; DEBUG-only: MetaMask
additionally). No restructuring of the connect→sign flow is needed, no
fallback-to-fixed-chain design is forced. This does not need an escalation
in the "here are real tradeoffs" sense the other three decisions do — but
it's included here per the task brief's explicit ask.

**Recommendation**: parse the numeric suffix of `connector.chainId`
(already-existing CAIP-2 string, e.g. `"eip155:1"`) into the `UInt64`
`buildAccountBindingText(chainId:)` expects, at the same point
`beginBinding()` constructs the binding-text type (§2.3) — `connector` is
already in scope at that call site (`EventBindingSheetView.performBinding(address:connector:)`).
No new state, no new async step.

**RESOLVED (user, 2026-08-03)**: use the existing `WalletConnector.chainId`,
parsed at the same point `beginBinding()` already runs — matching this
section's recommendation exactly. No restructuring of the connect→sign
flow.

### 6.c Unbinding

**Background**: Barnard 0.2.0's "EIP-191 wallet unbinding required"
(release notes) is implemented in `BarnardCoreOwnerKey.swift:321-390` and
specified in the spec's "Account unbinding" section (read directly, not
via the survey's paraphrase). It defines two signer paths — an
owner-key-authorized path (Barnard-native, signs a raw digest) and an
EOA/wallet-authorized path (must use the human-readable canonical
unbinding text via `personal_sign`, never the raw digest) — plus their
verifiers (`verifyAccountUnbinding`, both overloads). Confirmed by grep:
**no "unbind"/"revoke" symbol exists anywhere in `ios/Beid` today.**

**What the spec text actually says these rules bind**: every unbind-related
paragraph is phrased as a constraint on a *verifier* — "Verification
recovers the compressed key and requires it to equal `ownerPublicKey`,"
"A conforming verifier MUST NOT require an owner signature," "The API does
not aggregate revocations." Section "Future work" lists **"Host UX for
account rotation and wallet-authorized unbinding"** — explicitly future,
explicitly not required now. Section "Goals" (what v1 must deliver) says
only "Define deterministic rotation and unbinding *formats* before host UX
ships" — formats, not UX. Nothing in the spec states or implies that
producing a conformant *binding* additionally requires the producing host
to also expose an unbind affordance.

**Options**:

- **(a) No unbind path — build conformant binding-creation only (§2),
  defer unbind UX entirely.**
  - *For*: matches the spec's own "Future work" classification exactly;
    zero existing product/design surface to build against (no Figma frame,
    no DECISIONS.md entry, no user-facing need identified yet); a binding
    beid produces today with no matching unbind record is, per the spec's
    own model, simply "a long-lived idempotent fact" — valid, not
    incomplete, until/unless revocation is ever needed.
  - *Against*: none identified that isn't speculative.
- **(b) Build one unbind path now** (owner-key-authorized, or
  wallet-authorized) "to be maximally spec-complete."
  - *For*: nothing this convergence work specifically needs — included
    only for completeness of the options list.
  - *Against*: real scope creep with no product driver — no UI precedent,
    no decided which of the two signer paths a beid unbind flow would even
    use, and the spec itself says host UX for this is not expected at this
    stage. Building it now front-runs a product decision nothing here is
    asking for.

**Recommendation: (a).** Treat unbinding as out of scope for this
convergence work (already listed in §4), to be spec'd separately if/when
beid actually needs to support revocation.

**RESOLVED (user, 2026-08-03)**: option (a) — not implemented as part of
this convergence work, matching this section's recommendation exactly.
Binding-creation conformance only; unbind UX/flow is out of scope, to be
spec'd separately if ever needed.

### 6.d Migration of existing `BindingRecord`s

**Background**: `BindingRecordStore` is a flat on-device JSON file
(`binding-records.json`, app Documents directory) — the *only* place
non-conformant `BindingRecord`s exist. Per the task context: **zero
production users of beid exist today**, and Scan Slice-2 binding is new
enough that every existing on-device record anywhere is from TestFlight/
local testing, not real user data with real stakes.

One thing worth naming plainly rather than glossing over: `BindingRecord`'s
on-disk `Codable` shape (§2.4's note) **does not change** —
`deviceSignatureRHex`/`SHex`/`V` stay the same fields, just filled with
bytes from a different signer over a different message. That means an old
pre-conformance file **will decode successfully** under the new code (no
`DecodingError`) while being cryptographically meaningless under the new
scheme (device signature was K's, not owner key's; wallet signature was
over the old opaque digest, not the new canonical text) — a silent
decode-succeeds/verify-fails trap if left alone, not merely "stale data."

**Recommendation**: no migration code. Rename the store's file
(`binding-records.json` → e.g. `binding-records-v2.json`) so old records
are simply orphaned on disk and never read again — the cheapest possible
correct answer, and it sidesteps the decode-succeeds trap above by
construction (the new code never opens the old filename). No version
field, no migration function, no user-facing reset flow — this is
appropriately low-drama for data with zero real stakes, per the task's own
framing, while still being an explicit choice rather than a silently
unaddressed gap.

**RESOLVED (user, 2026-08-03)**: no migration code. Rename the store's file
to `binding-records-v2.json`, matching this section's recommendation
exactly, so old records are orphaned by construction. The reasoning the
user approved is the one this section leads with, restated here so it
isn't lost: `BindingRecord`'s on-disk `Codable` shape is unchanged between
the old and new schemes, so an old pre-conformance file would **decode
successfully** under the new code while being **cryptographically
meaningless** (wrong signer, wrong signed content) — this is a
silent-wrong-data hazard, not merely staleness. Renaming the file removes
that hazard **structurally** (the new code never opens the old filename)
rather than relying on anyone remembering to check for it.

## 7. Acceptance criteria and sub-slicing

**Yes, split** — matches `scan-slice2-redesign.md` §10's precedent, and
gh#88 itself already says so ("Scan Slice-2 の identity 層の作り直しで、
小さなパッチではありません" — a rework of the identity layer, not a small
patch). Three sub-slices, ordered by dependency and risk, the same
discipline `scan-slice2-redesign.md` applied to its own 2a/2b/2c split:

### 7.1 Sub-slice A — owner-key derivation fix (§2.1)

Lowest risk: an internal KDF swap behind an unchanged public shape
(`publicKeyCompressed() -> Data`), no UI, no wallet dependency. Unblocks
B and C.

- `OwnerKeyProvider.publicKeyCompressed()` calls
  `BarnardCoreSigning.deriveOwnerKeyPair(accountSecret:)`, not
  `deriveSigningKeyPair`.
- `OwnerKeyProvider` gains `signSelfProof`/`signWalletAcknowledgement`
  (§2.1); no public API on `OwnerKeyProvider` returns raw private-key
  bytes (checkable by inspection/grep — no `privateKey` in its public
  surface).
- Unit test (injected fixed `keyStorage`) asserts
  `publicKeyCompressed()` equals Barnard's pinned zero-seed vector
  (`03351e5165d083f53425fc4a51e7228d53e88eb2899bcb6a83368a8aafaa1de5f4`,
  §5) and, with the sequential-byte seed, its second pinned vector
  (`03879beac8b548009124867a99a358aeb34ff42f957f868bbc83339568b16d9c67`).
- Note, not a criterion: this silently changes the *value* of the owner
  key derived from an already-stored seed on any device that already ran
  the old code — inconsequential per D1 (no continuity promised for v1)
  and §6.d (zero production stakes).
- `xcodebuild -project ios/Beid.xcodeproj -scheme Beid -destination
  'platform=iOS Simulator,name=iPhone 17 Pro' clean build` = BUILD
  SUCCEEDED. `scripts/lint.sh` = 0 violations.
- Xcode Cloud PR CI (`BeidTests`) green — the actual gate per §5, given
  the local-simulator constraint on this machine.

### 7.2 Sub-slice B — self-proof production (§2.2)

Depends on A (`OwnerKeyProvider.signSelfProof`). No UI, no wallet
dependency — isolated like A, but a genuinely new layer rather than a
fix to an existing one.

- `eventIdHash` construction implemented and unit-tested (recommended:
  `SHA256(UTF8(eventCode))`, §2.2).
- Self-proof signed once per event, at session end (eninEnd known), not
  at `beginEventFound` — test asserts no self-proof exists mid-session.
- Structural byte-layout unit test against Barnard's pinned 135-byte
  self-proof offsets/values (§5), not just a build→sign→verify round
  trip using beid's own implementation on both ends.
- Self-proof bytes are never passed to `windowReportPayload`,
  `BarnardEngine`'s advertise/GATT-facing APIs, or any other on-wire
  path — grep-checkable; confirms §4's boundary holds in the actual diff,
  not just in this document.
- Stored in a new local store (flat JSON, on-device only, same pattern as
  `BindingRecordStore`/`WindowReportStore`) — nothing consumes it yet,
  which is expected (§2.2).
- `xcodebuild ... clean build` = BUILD SUCCEEDED. `scripts/lint.sh` = 0
  violations. Xcode Cloud PR CI green.

### 7.3 Sub-slice C — canonical wallet-binding text + wallet-ack (§2.3, §2.4, §3)

Depends on A (owner-key signing methods) and on §6.a/§6.b being resolved
(domain, chain-id source) — the highest-risk, most user-visible slice
(§3's UX delta lands here).

- `BindingMessage`'s body is replaced by the new binding-text type (§2.3)
  calling `buildAccountBindingText`; the beid-chosen domain (§6.a) and
  `connector.chainId`-sourced `chainId` (§6.b) are wired in.
- Every wallet `personal_sign` call site (Coinbase, Reown, MetaMask under
  DEBUG) passes hex-encoded canonical-text **bytes**, not a SHA-256
  digest, as the message parameter — grep-checkable that no call site in
  the binding path computes `SHA256(...)` before signing anymore.
  `digestHex` renamed to `messageHex` throughout the binding path (§2.3).
- `SensingCoordinator.completeBinding` calls
  `OwnerKeyProvider.signWalletAcknowledgement` (owner key), not
  `identity.sign` (K) — grep-checkable that `identity.sign` no longer
  appears anywhere in the binding-completion path (only in
  `closeWindow`'s window-report path, confirming §4's scope boundary
  holds in the actual diff).
- Unit test reconstructs Barnard's own pinned canonical-binding-text
  golden vector (§5's exact input set) through beid's new type and
  asserts byte-exact equality with Barnard's pinned 407-byte text **and**
  its pinned EIP-191 digest
  (`1aad6c43694a0e64bf3994959907b7392a590a1e7139bc9f52a86dc71709dc44`) —
  the concrete conformance test §5 requires, not a self-consistency test.
- `BindingRecordStore`'s file renamed per §6.d
  (`binding-records-v2.json`); test/grep-checkable that the old filename
  is never read by the new code.
- Any new/changed user-facing string introduced by this slice (none
  identified in `EventBindingSheetView.swift` itself per §3, but flagged
  here in case implementation surfaces one, e.g. a renamed failure
  reason) gets `needs_review` `ja`/`zh-Hans`/`es`/`fr` translations in the
  same PR, per `AGENTS.md`.
- `xcodebuild ... clean build` = BUILD SUCCEEDED. `scripts/lint.sh` = 0
  violations. Xcode Cloud PR CI green.

## 8. Branch note

Base each sub-slice on `main` after the previous one merges (A → B → C),
same convention `scan-slice2-redesign.md` §12 used for its own sub-slices.
No in-flight branch work is known to conflict with this area as of this
session.
