# Survey — Barnard owner-key/binding compatibility (0.2.0 pinned) and the 0.3.0 delta

Status: survey only, no code/pin changes made. Author: Worker `a-20260803-005`,
for SubPM `a-20260731-027`.

Scope: is beid's Scan Slice-2 owner key / commitment / wallet-binding
implementation compatible with what Barnard 0.2.0 (currently pinned,
`exactVersion: 0.2.0`, revision `8a70ac1eeb21f4639dcf90c6cde1b0446da06d8b`)
specifies, and what does 0.3.0 (not pinned) change.

## Bottom line, up front

**Beid's wallet-binding scheme is not merely "not yet aligned" with Barnard's
owner-key spec — it does not intersect with it at all.** Three independent,
compounding divergences, each sufficient on its own to make verification
fail:

1. Beid's "owner key" is derived by calling the wrong Barnard function
   (`deriveSigningKeyPair`, the *event-signing-key* KDF) instead of the
   dedicated `deriveOwnerKeyPair` API that Barnard 0.2.0 already publicly
   exports. From the same random seed, these two functions produce
   **different key pairs** (different HKDF `info` string, different IKM
   construction). Nothing beid calls an "owner key" today would recognize
   itself as one to a Barnard-conformant verifier.
2. Beid's wallet ceremony binds a wallet directly to the **per-event
   signing public key K** (`BindingMessage.eventSigningPublicKey`). Barnard's
   protocol binds a wallet to the **owner public key**, with a *separate*
   owner-key-signed "self-proof" linking `K` to the owner key. Beid has no
   self-proof at all, and its owner key never appears in the wallet-signed
   content.
3. Beid's wallet signs a bare `0x`-prefixed SHA-256 hex digest of its own
   ad hoc byte layout. Barnard's `verifyWalletBinding` reconstructs a specific
   11-line, human-readable canonical text (domain, wallet, owner key,
   chain ID, scope, nonce, RFC 3339 timestamp) and requires the wallet
   signature to be over *that exact UTF-8 text*, via `personal_sign`. Beid's
   signed payload is a different length, different content, and structurally
   cannot reconstruct into Barnard's canonical text. A Barnard-conformant
   verifier (Android/BarnardCore, or any future server-side verifier) that
   is handed a beid binding has nothing to check it against — it isn't
   parseable as a Barnard `barnard-account-binding:v1` ceremony.

Verdict for Q1: **divergent-and-incompatible**. Verdict for Q2: **divergent
-and-incompatible**, both directions (beid's binding cannot be verified by
a Barnard verifier, and a Barnard-conformant binding is not what beid
produces). This is a pre-existing gap, not something the 0.2.0→0.3.0 upgrade
introduces or worsens — 0.3.0 makes zero changes to any owner-key file (see
Q3). It was there the moment beid pinned 0.2.0 and hand-rolled its own
scheme instead of calling the SDK's owner-key API, which already shipped in
that same pinned version.

The 0.3.0 upgrade itself (Q3) is source-compatible for beid as it stands —
unrelated to the above.

---

## Method / provenance note

The local Xcode DerivedData SwiftPM checkout
(`~/Library/Developer/Xcode/DerivedData/Beid-cjbuzceszyhuizauchfkskzamtcu/SourcePackages/checkouts/barnard`)
is **stale**: it is checked out at `v0.1.0` (revision `f9c930d`), not the
`v0.2.0` the project actually pins. It was not used as a source of truth.
Instead, `levarac/barnard` (confirmed via `gh repo view levarac/barnard` —
description "A transport-agnostic Scan/Advertise sensing SDK"; this is
**not** `thegreeting/barnard`) was cloned read-only into a scratch directory
outside the beid repo and both `v0.2.0` and `v0.3.0` tags were checked out
and read directly. This clone/checkout touched nothing inside the beid
working tree and involved no git-mutating command against the beid repo.

---

## 1. Owner key: derivation, curve, commitment construction

**Curve**: both sides use secp256k1 — no divergence there.

**Derivation — this is where it diverges.** Barnard 0.2.0 defines a
dedicated, public owner-key API:

`packages/swift/barnard/Sources/BarnardCore/BarnardCoreSigning.swift`:

```swift
public static let ownerKeyInfo = "barnard-owner"

public static func deriveOwnerKeyPair(
  accountSecret: [UInt8]
) -> BarnardCoreSigningKeyPair {
  precondition(accountSecret.count == 32, "accountSecret must be 32 bytes")
  var seed = BarnardCorePrimitives.hkdfSha256(
    inputKeyMaterial: accountSecret,
    info: Array(ownerKeyInfo.utf8),
    outputByteCount: 32
  )
  var privateKey = BarnardCoreSecp256k1.Field.reduceOnce(
    BarnardCoreSecp256k1.UInt256(bytes: seed),
    BarnardCoreSecp256k1.curveOrder
  )
  while privateKey.isZero { seed = BarnardCorePrimitives.sha256(seed); /* retry */ }
  ...
}
```

i.e. `deriveOwnerKeyPair` = `HKDF-SHA256(IKM = AccountSecret, salt = 32 zero
bytes, info = "barnard-owner", 32 bytes)` → reduce mod curve order → retry
on zero. This exactly matches `specs/092-owner-key/spec.md`'s "Owner-key
derivation" section (steps 1–5).

Beid's `OwnerKeyProvider.swift:53-60` instead calls the sibling
**event-signing-key** function:

```swift
let keyPair = BarnardCoreSigning.deriveSigningKeyPair(deviceSecret: seed, eventCode: Self.derivationContext)
```

where `deriveSigningKeyPair` (`BarnardCoreSigning.swift:44-72`) computes
`HKDF-SHA256(IKM = deviceSecret + UTF8(eventCode), info = "barnard-sign",
32 bytes)` — a **different IKM construction** (concatenates a fixed
constant string `"beid-owner-key:v1"` as a fake `eventCode`) **and a
different `info` tag** (`"barnard-sign"` vs. `"barnard-owner"`). Feeding the
same 32-byte seed into `deriveSigningKeyPair(deviceSecret:, eventCode:
"beid-owner-key:v1")` vs. the real `deriveOwnerKeyPair(accountSecret:)`
produces two unrelated key pairs. Beid's own code comment
(`OwnerKeyProvider.swift:16-19`) says it "reuses `BarnardCoreSigning`'s
already-tested secp256k1 derivation... rather than hand-rolling
elliptic-curve math" — true in spirit, but it reuses the *wrong* one; the
right one (`deriveOwnerKeyPair`) already exists in the same pinned package
and export surface and is not called anywhere in beid.

**Commitment construction.** Barnard 0.2.0 does not define a raw-hash
"commitment" at all; the closest analogous concept is the **self-proof**
(`specs/092-owner-key/spec.md` "Message formats and behavior" §1,
`BarnardCoreOwnerKey.swift:101-149`):

```
offset  size  value
0       21    UTF-8 "barnard-self-proof:v1"
21      32    eventIdHash
53      33    eventSigningPublicKey (compressed SEC1)
86       8    eninStart (unsigned big-endian)
94       8    eninEnd (unsigned big-endian)
102     33    ownerPublicKey (compressed SEC1)
total  135
```

— and critically, this 135-byte message is not merely hashed, it is
**signed by the owner private key** (`signSelfProof`, RFC 6979 deterministic
ECDSA, low-S, `r‖s‖recoveryId` "Barnard Recoverable secp256k1 Signature
Profile v1"). A verifier recovers the signer from the signature and checks
it equals `ownerPublicKey` — the self-proof is a proof of possession, not
just a fingerprint.

Beid's `EventCommitment.compute` (`EventCommitment.swift:17-20`):

```swift
static func compute(eventSigningKey: Data, ownerKey: Data, salt: Data) -> Data {
  let message = Array(eventSigningKey) + Array(ownerKey) + Array(salt)
  return Data(BarnardCoreCrypto.sha256(message))
}
```

is a plain SHA-256 of concatenated public values with **no owner-key
signature at all** — anyone who observes `eventSigningKey`, `ownerKey`, and
`salt` on the wire could recompute the identical hash without controlling
any private key. It has no domain tag, no `eventIdHash`, no ENIN range
(replaced by an unstructured `salt`), and is explicitly documented in-repo
as provisional (`EventCommitment.swift:12-15`, `scan-slice2-redesign.md`
§11: "Exact commit/report wire-byte encoding... is not finalized"). So this
was already known-incomplete by beid's own spec — the finding here is that
it's not just incomplete, it's a structurally different primitive
(unsigned hash vs. signed self-proof) from what 0.2.0 actually ships.

**Does 0.2.0 expose an owner-key API beid should call instead of rolling its
own?** Yes — `BarnardCoreSigning.deriveOwnerKeyPair(accountSecret:)` for
derivation, and `BarnardCoreSigning.{buildSelfProofMessage,
signSelfProof, verifySelfProof}` for the commitment-equivalent. None of
these are called anywhere in beid (confirmed by grep across
`ios/Beid/Sensing`).

**Verdict: divergent-and-incompatible.**

---

## 2. Binding message vs. Barnard's wallet-binding format

**Beid's format** (`BindingMessage.swift:22,40-57`, used from
`SensingCoordinator.swift:322-328,349`):

- `canonicalBytes` = `"beid-binding/v1"` (schema tag, UTF-8) ‖ UTF-8
  `eventCode` ‖ compressed secp256k1 `eventSigningPublicKey` (K, **not** the
  owner key) ‖ big-endian `Int64` unix-ms `issuedAt`.
- Wallet signs (`walletDigestHex()`): `"0x" + hex(SHA256(canonicalBytes))` —
  a bare 32-byte digest, passed as the `personal_sign` "message" parameter
  verbatim. Confirmed at every wallet-SDK call site: `sdk.personalSign(message:
  digestHex, address:)` (`MetaMaskConnector.swift:233`), `.personal_sign(address:,
  message: digestHex)` (`CoinbaseWalletConnector.swift:191-197`), Reown's
  `personal_sign` request built from the same `digestHex`
  (`ReownWalletConnectClient.swift:159-182`). Standard `personal_sign`
  semantics treat a `0x`-prefixed hex string as raw bytes to be
  EIP-191-wrapped — i.e. the wallet computes
  `keccak256(0x19 ‖ "Ethereum Signed Message:\n" ‖ "32" ‖ <32 raw SHA-256
  bytes>)`. That is a real, standards-following signature — just not one
  that matches anything Barnard checks (see below).
- Device "countersigns" the *same* `canonicalBytes`
  (`SensingCoordinator.swift:349`: `identity.sign(eventCode: message.eventCode,
  bytes: message.canonicalBytes)`), using `BarnardIdentity.sign` — which
  derives the **event signing key** (not owner key) and signs
  `SHA256(canonicalBytes)` with it. So K effectively self-attests to its own
  binding message; the owner key is not involved in this ceremony at all.

**Barnard's format** (`specs/092-owner-key/spec.md` "Canonical wallet-binding
text", `BarnardCoreOwnerKey.swift:34-66`):

```
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

signed via `personal_sign` over the **literal UTF-8 text** (not a digest of
it) — `computeEip191Digest` wraps the whole multi-line string, not a
32-byte hash of some other encoding. Verification
(`verifyWalletBinding`) reconstructs this exact text from expected fields
and requires byte-exact equality before even looking at the signature. It
then separately requires a **wallet acknowledgement**: the owner key signs
`"barnard-wallet-ack:v1" ‖ walletAddress(20) ‖ SHA256(walletSignatureBytes)`
(`buildWalletAcknowledgementMessage`, `BarnardCoreOwnerKey.swift:177-207`) —
this is the "device countersign" analog, and it is signed by the **owner
key**, not the event signing key, and it references the *wallet's*
signature, not the binding text.

**The exact deltas, concretely:**

| Field | Beid | Barnard |
|---|---|---|
| Domain tag | `"beid-binding/v1"` (16 bytes, no version-prefix convention match) | `"barnard-account-binding:v1"` (used inside the text, not as a raw prefix) |
| Bound identity | per-event signing key K (33B) | owner public key (33B) |
| Message the wallet actually signs | 32-byte SHA-256 digest, hex-encoded, as opaque "message" bytes | full human-readable ASCII/UTF-8 ceremony text (domain, wallet, owner key, chain ID, scope, nonce, issuedAt) |
| Domain / Chain-ID / Nonce / Scope | absent entirely | required fields |
| Device/owner counter-signature | K signs the same `canonicalBytes` beid defined | owner key signs a *different* message (`barnard-wallet-ack:v1` ‖ walletAddress ‖ SHA256(wallet signature)) |
| Timestamp format | big-endian `Int64` unix-ms, embedded in signed bytes | RFC 3339 UTC string, embedded in signed text |

There is no partial overlap to converge from incrementally — the two are
different protocols occupying the same conceptual slot. Converging would
mean beid stops defining its own `BindingMessage` type and instead calls
`BarnardCoreSigning.buildAccountBindingText` / `signWalletAcknowledgement` /
`verifyWalletBinding` directly, binding the **owner key** (once beid also
adopts `deriveOwnerKeyPair`, per §1) rather than K.

**Unbind path.** Beid has no unbind path today — confirmed by grep, no
"unbind"/"revoke" symbol exists in `ios/Beid`. Barnard 0.2.0's "EIP-191
wallet unbinding required" (release notes; verified in source at
`BarnardCoreOwnerKey.swift:321-390`, "Account unbinding" in the spec) is a
**verifier-side/format rule on Barnard's own binding/unbinding records** —
it constrains what a conformant *verifier* must accept/reject for an
unbinding ceremony, and constrains the owner-key-authorized unbind path to
sign a raw digest while the EOA-authorized path must use the human-readable
canonical unbind text via `personal_sign`. It does not, by itself, impose
any obligation on beid as an app *today*, because beid isn't producing
Barnard-conformant bindings in the first place — there is nothing of
beid's for this rule to apply to yet. It becomes relevant only at the point
beid adopts the real Barnard binding scheme (§1/§2 above): at that point,
supporting revocation means implementing one of these two exact unbind
message formats, not an ad hoc one.

**Verdict: divergent-and-incompatible**, bluntly and without qualification.
Any verifier checking a beid binding against the Barnard 0.2.0 spec (a
prospective Android/BarnardCore verifier, or any future server-side
verifier) rejects it, because it cannot even parse beid's signed payload as
a `barnard-account-binding:v1` ceremony — wrong bound key, wrong message
shape, wrong signer for the second signature, missing required fields.

---

## 3. 0.3.0 API delta — verified against source diff, not release notes

Diffed `v0.2.0` → `v0.3.0` directly (`git diff --stat v0.2.0 v0.3.0`, full
repo). Total footprint: **`BarnardEngine.swift` (+195/-7), a new file
`BarnardEventInfo.swift` (+307, new), and its tests** — plus Android
mirrors, CI files, and `specs/113-event-info-discovery/spec.md`. Nothing
outside these touches Swift source. In particular:

- **`BarnardCoreOwnerKey.swift`, `BarnardCoreSigning.swift`,
  `Barnard/BarnardIdentity.swift`, `Barnard/BarnardSigning.swift`: zero
  diff.** The owner-key/binding incompatibility in §1–2 is entirely
  independent of the 0.2.0→0.3.0 decision; upgrading changes nothing about
  it, and staying on 0.2.0 doesn't avoid it either since it's already
  present.
- `Package.swift`: no diff (manifest-level API surface unchanged).

**`BarnardEvent` enum — additive, confirmed non-breaking for beid
specifically.** 0.3.0 adds one new case:

```swift
public struct BarnardEventInfoHintEvent {
  public let peripheralId: UUID
  public let eventInfo: BarnardEventInfo
  public let additionalNamesOmitted: Bool
  public let additionalEventsOmitted: Bool
}

public enum BarnardEvent {
  case state(BarnardState)
  case constraint(BarnardConstraintEvent)
  case error(BarnardErrorEvent)
  case detection(BarnardDetectionEvent)
  case rssiUpdate(BarnardRssiUpdateEvent)
  case eventInfoHint(BarnardEventInfoHintEvent)   // new in 0.3.0
}
```

The release notes claim this is additive and safe for existing clients.
Verified: beid's only switch over `BarnardEvent` is
`SensingCoordinator.swift:113-124`:

```swift
switch event {
case .state(let state): ...
case .detection(let detection): ...
default:
  ...
}
```

It already has a `default:` arm (not an exhaustive case list), so the new
`.eventInfoHint` case falls through to `default` and **the switch keeps
compiling unchanged**. Grepped the rest of `ios/Beid` for switches over
other Barnard-defined enums (`BarnardState`, `BarnardConstraintEvent`,
`BarnardErrorEvent`, `BarnardDetectionEvent`, `BarnardRssiUpdateEvent`) —
`SensingCoordinator.swift` is the only file referencing any of them, and
none of those types changed between 0.2.0 and 0.3.0 per the diff.

**GATT/init/public-method surface**: the diff to `BarnardEngine.swift` adds
a new characteristic UUID, new private state, and one new public method
(`configureEventInfoServing(organizerDesignated:eventActiveForDiscovery:eventDisplayName:)`,
all-defaulted parameters) — no existing public method's signature changes,
nothing is renamed, nothing new is required at any existing call site.
Confirmed `configureEventInfoServing` is never called in beid today, so its
addition is inert until adopted.

**Release-notes claims checked against source, not trusted at face
value**: "B005 is additive," "new `eventInfoHint` engine event," "serve
policy defaults to off" (`BarnardEventInfoServePolicy.init` defaults both
booleans to `false`, and `mayServe` requires both `true`), and "B002/B003/
B004 unchanged" (their characteristic UUIDs and read/response logic are
untouched in the diff, only additively wrapped) — **all four confirmed
accurate against the actual diff**, no discrepancy found between what the
release notes say and what the source does.

**Verdict: source-compatible.** The 0.2.0 → 0.3.0 upgrade would not break
beid's current build as it stands.

---

## 4. B005 walk-up discovery — fit with `EventCodeEntryView` (brief, not a design)

`EventCodeEntryView.swift` is beid's wallet-optional manual-join fallback:
user types an event code blind ("Ask the event organizer for the code").
B005 (`specs/113-event-info-discovery/spec.md`, `BarnardEventInfo.swift`)
lets a nearby *already-known* peer broadcast a bounded, human-readable
`eventDisplayName` + `eventCodeHash` before a scanning device has the code
— surfaced to the app as the new `.eventInfoHint` engine event.

Conceptual fit is real but partial: B005 helps a device **discover which
event is nearby** (a hint), it does not let the device **join** without the
code — admission is explicitly kept out-of-band by the spec ("a hint may
speed discovery but never auto-joins"). So the plausible use is showing a
"detected nearby: <event name>, tap to prefill" affordance inside/adjacent
to `EventCodeEntryView`, not replacing the code-entry step. It also requires
an organizer-side opt-in (`configureEventInfoServing`, defaults off) that
beid doesn't currently expose anywhere in its own UI/config, so the
serve-side half is a separate, symmetrical piece of work (likely an
organizer/host-facing surface beid doesn't have yet at all).

**Rough size estimate: small-to-medium.** Central-side consumption
(handling `.eventInfoHint` in `SensingCoordinator`, surfacing a suggestion
in `EventCodeEntryView`) is a contained, single-sub-slice-sized change.
Serve-side (`configureEventInfoServing` + a UI/policy for who counts as
"organizer-designated") is new surface with no existing analog in beid and
would need its own scoping — not sized further here per the task's "don't
design it" instruction.

---

## 5. Upgrade mechanics — 0.2.0 → 0.3.0 (documented only, not performed)

Confirmed by grep across the repo for every non-Swift-source reference to
"Barnard"/"barnard" (`README.md`, `AGENTS.md`, `ios/project.yml`,
`ios/README.md`, `android/README.md`, `docs/specs/scan-protocol-model.md`,
`docs/specs/scan-slice2-redesign.md`) plus the pin files themselves. The
concrete edits an upgrade would require:

1. **`ios/project.yml:10`**: `exactVersion: 0.2.0` → `exactVersion: 0.3.0`
   under the `packages.Barnard` entry.
2. **`ios/Beid.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`**:
   the `barnard` pin's `"revision"` (currently
   `8a70ac1eeb21f4639dcf90c6cde1b0446da06d8b`) and `"version"` (currently
   `"0.2.0"`) fields, and `originHash` at the top of the file (SwiftPM
   recomputes this from the full pin set — not something to hand-edit).
   Per `levarac/barnard` tag metadata, `v0.3.0`'s commit is
   `57a8a7df7f4b2078150eabff4c06a46cfb2aae0f`.
3. Regenerate `ios/Beid.xcodeproj` via `xcodegen generate` from `ios/`
   after the `project.yml` edit, per `AGENTS.md`'s standing rule (never
   hand-edit the `.xcodeproj`). `Package.resolved` itself is normally
   regenerated by Xcode/`xcodebuild` resolving packages, not hand-edited.
4. No other file in the repo references a Barnard version number or
   revision — `README.md`/`AGENTS.md`/the two `docs/specs/*.md` files
   mention "Barnard" only descriptively (SDK name, protocol concepts),
   with no version string to update. `android/README.md`'s mention is
   unrelated to this iOS pin (beid's Android counterpart, if any, pins
   independently — out of scope here).

No build/test/simulator run was attempted for this — this is a
read/compare/document task per the assigned scope, and the local
CoreSimulator external-volume issue would block any real device/simulator
run regardless.
