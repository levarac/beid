# Design — Keychain/iCloud storage for DeviceSecret and the owner-key seed (gh#77)

Status: **DESIGN DOCUMENT ONLY — no code written.** Per the PM's instruction
relayed through SubPM `a-20260809-001`: "moving the DeviceSecret and
owner-key seed into the Keychain is a security change and also reserved. It
is on the list but bring me the design before implementing. It must include
a review of `OwnerKeyProvider`'s caching policy." This document is that
design. It does not implement anything, and nothing here should be treated
as authorization to start implementation — that is a separate, later
approval step.

Author: Worker `a-20260809-027`, for SubPM `a-20260809-001`.

Tracks: `thegreeting/beid#77` ("[security] DeviceSecret を Keychain/iCloud
化").

**Method note**: every factual claim about current beid code below is from
`ios/Beid/Sensing/OwnerKeyProvider.swift` and
`ios/Beid/Sensing/SensingCryptography.swift` in this worktree (branch
`issue-77-keychain-design`, based on `origin/main` at `aa19b0a`), plus
`ios/Beid/Navigation/AppCoordinator.swift` and `ios/Beid/App/BeidApp.swift`
for instantiation-lifetime tracing, and `ios/project.yml` for the Barnard
package pin. Every factual claim about Barnard's own code is from a fresh
`git clone` of `https://github.com/levarac/barnard.git` checked out to the
exact pinned revision
(`57a8a7df7f4b2078150eabff4c06a46cfb2aae0f`, tag `0.3.0`, confirmed against
`ios/Beid.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`),
not from memory or the issue text. `DECISIONS.md` and `AGENTS.md` were read
in full directly. `gh issue view 77 --repo thegreeting/beid --comments` was
read directly, not paraphrased from the SubPM's summary — this surfaced a
comment (§4.3) that materially sharpens the caching-policy question the PM
asked for.

## 0. Two corrections to the task framing, found while verifying it

Both matter for scoping and are stated here up front rather than buried,
per the task's own instruction to "verify whether that's still accurate"
rather than assume the briefing is current.

1. **`docs/specs/owner-key-seed-read-failure.md` (gh#156) is not merged.**
   The task described it as "already-approved, already-merged." It is
   approved (the spec file exists, committed on a feature branch) but its
   implementation is **PR #182, currently OPEN**, and the spec file itself
   is not present on `origin/main` — it lives only on branch
   `issue-156-owner-key-seed` (commits `5a9eb8a` spec, `24294cb`
   implementation), neither of which is an ancestor of this worktree's
   `origin/main`-based HEAD. This document treats #156 as a **pending,
   not-yet-landed dependency**, and §3.4 below designs for both possible
   landing orders rather than assuming #156 is already in place.
2. **DECISIONS 2026-07-30's "Barnard(直江さん)側で検討" framing describes
   only part of this issue correctly.** That entry says `DeviceSecret`'s
   Keychain/iCloud hardening should be considered "on Barnard's side." Read
   against the actual code (§2 below), that is accurate for `DeviceSecret`
   itself — but gh#77's title bundles `DeviceSecret` together with the
   **owner-key seed**, which is a separate, **beid-owned** value with its
   own separate storage adapter that beid controls directly today. The two
   halves of this issue have different owners and different actionability.
   This is the single most important scoping finding in this document —
   see §2.

## 1. Scope: local-only Keychain vs. iCloud-synced Keychain

**Recommendation: local-only Keychain for the owner-key seed
(`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, no iCloud sync). Do not
recommend iCloud Keychain sync in this document.**

"Keychain/iCloud 化" in the issue title bundles two technically distinct
choices:

- **Local Keychain** (device-bound, `...ThisDeviceOnly` accessibility
  classes): the secret is encrypted at rest by the Secure Enclave-backed
  class key and excluded from iCloud Keychain sync and from unencrypted
  device backups. It has *zero* cross-device continuity — a reinstall or
  new device still generates a fresh value, exactly like today's
  `UserDefaults` storage does. It only changes *where and how* the bytes
  sit on the one device.
- **iCloud Keychain sync** (accessibility classes without
  `ThisDeviceOnly`, plus `kSecAttrSynchronizable = true`): the same value
  becomes available on every device signed into the same iCloud account.
  This **would** give the owner key cross-device continuity as a direct
  side effect of the storage mechanism, even though nothing about this
  issue asks for that as a product feature.

`DECISIONS.md` 2026-07-30 ("D1 owner key 確定") states plainly that owner
key continuity across device change/loss is a **deferred, non-blocking
residual point** for v1 ("残論点(非ブロッカー...): owner key の機種変・
紛失時の継続性"), and `docs/specs/scan-slice2-redesign.md` §0 goes further:
"Moving that storage to iCloud Keychain is explicitly **not** part of this
work — it is a deferred slice." Recommending iCloud sync here would make a
product-continuity decision through a security-hardening issue's back door,
exactly the entanglement the task asked this document to flag rather than
silently resolve. Local-only Keychain hardens the storage (encryption at
rest, backup exclusion, OS-enforced access control) without touching the
continuity question at all — it keeps this issue's scope to "where the
bytes are stored more securely," matching D1's still-standing "no
continuity for v1" position.

**The tension, stated explicitly rather than decided silently (per the
task's instruction):** iCloud Keychain sync is the cheapest available path
to owner-key continuity, and D1's residual note lists "独立生成+iCloud
バックアップ" as one of the two live options for solving continuity later.
Choosing local-only now does not foreclose adding sync later — it is an
additive change to the same Keychain item's attributes — but it does mean
this document is not the place that decision gets made, and whoever
eventually revisits owner-key continuity should treat "should the existing
Keychain item also sync" as one of their live options, not start over.

## 2. What's beid's to change vs. Barnard's (KMP-002)

This is the finding that most changes the shape of gh#77 from what its
title suggests. The two secrets named in the issue are **not symmetric**
with respect to what beid can change unilaterally.

### 2.1 Owner-key seed — beid's own storage, directly actionable

`OwnerKeyProvider.keyPair()` (`OwnerKeyProvider.swift:92-98`) calls
`BarnardCoreKeyManager.loadOrCreate(key:minimumByteCount:generatedByteCount:storage:randomSource:)`
— a pure function in the public `BarnardCore` module — passing beid's own
`storage: keyStorage` argument. That argument defaults to
`BeidUserDefaultsKeyStorage()` (`OwnerKeyProvider.swift:40`), a **struct
beid itself defines** (`OwnerKeyProvider.swift:108-122`) conforming to
`BarnardCoreKeyStorage`:

```swift
struct BeidUserDefaultsKeyStorage: BarnardCoreKeyStorage {
  let defaults: UserDefaults
  func bytes(forKey key: String) -> [UInt8]? {
    defaults.data(forKey: key).map(Array.init)
  }
  func setBytes(_ bytes: [UInt8], forKey key: String) {
    defaults.set(Data(bytes), forKey: key)
  }
}
```

`BarnardCoreKeyManager.loadOrCreate` only ever calls the `storage`
parameter's two methods — it has no knowledge of `UserDefaults`. Swapping
`BeidUserDefaultsKeyStorage` for a beid-owned `BeidKeychainKeyStorage`
implementing the same two-method `BarnardCoreKeyStorage` protocol is a
**pure beid-side change**: one new struct, one changed default-argument
value at `OwnerKeyProvider.swift:40`. No Barnard change, no KMP-002
crossing — `BarnardCoreKeyStorage`'s protocol shape (synchronous,
`[UInt8]?` in/out) is left untouched, and the Keychain APIs beid would call
inside the new struct (`SecItemAdd`/`SecItemCopyMatching`/`SecItemUpdate`)
are also synchronous, so the two methods' signatures need no change either.
**This half of gh#77 is fully actionable by beid alone, today.**

### 2.2 `DeviceSecret` — fully internal to Barnard, zero injection point

`DeviceSecret` is not a beid type. Grepping this repo confirms it appears
**only inside `OwnerKeyProvider.swift`'s doc comments** (e.g.
`OwnerKeyProvider.swift:11-13`) as a reference to a different, external
concept — beid has no `DeviceSecret` type, field, or storage call
anywhere in `ios/`. Reading the pinned Barnard source directly:

- `DeviceSecret` is generated/stored by `BarnardIdentity`
  (`packages/swift/barnard/Sources/Barnard/BarnardIdentity.swift`) and
  independently by `BarnardRpidGenerator`
  (`.../BarnardRpidGenerator.swift`), both under the same storage key
  `"barnard.rpidSeed"` (`BarnardIdentity.swift:33`,
  `BarnardRpidGenerator.swift:16`) — a doc comment on `BarnardIdentity`
  confirms this is intentional: "shares the same on-device `DeviceSecret`
  storage... as `BarnardEngine`/`BarnardRpidGenerator`."
- `BarnardIdentity`'s public initializer takes **no parameters at all** —
  `public init() { keyStorage = BarnardUserDefaultsKeyStorage() ... }`
  (`BarnardIdentity.swift:37-38`). There is no overload, no default
  parameter, nothing a caller outside the `Barnard` module can pass to
  substitute a different storage.
- `BarnardUserDefaultsKeyStorage` itself
  (`packages/swift/barnard/Sources/Barnard/BarnardPlatformDependencies.swift:17-30`)
  has no `public` modifier — it is not part of Barnard's public API surface
  at all, only visible inside the `Barnard` module.
- `BarnardEngine` (the sensing client) hardcodes
  `private let rpid = BarnardRpidGenerator()` (`BarnardEngine.swift:188`)
  with its own public initializer, `override public init()`
  (`BarnardEngine.swift:329`), also taking no storage parameter.
  `BarnardRpidGenerator`'s own initializer (`BarnardRpidGenerator.swift:38-41`)
  *does* technically accept an injectable `keyStorage` argument, but
  `BarnardRpidGenerator` itself is declared `final class` with no `public`
  modifier (`BarnardRpidGenerator.swift:13`) — it is not visible outside
  the `Barnard` module either, so that injection point is unreachable from
  beid regardless.

**Conclusion: beid has no code-level hook to change where `DeviceSecret`
is stored.** This is not a case of beid choosing not to use an available
seam — the seam does not exist in Barnard's current public API. Per
`AGENTS.md`'s KMP-002 ("Barnard remains native on both platforms...
`shared/` may check only boundary shape"), and per the plain fact that
`BarnardIdentity`/`BarnardEngine`'s public surface offers nothing to
inject, **the `DeviceSecret` portion of gh#77 is not actionable from
beid's side alone.** It requires a Barnard-side change — either Barnard
adding a `keyStorage:`/`randomSource:` parameter to `BarnardIdentity.init`
and `BarnardEngine.init` (mirroring the pattern beid already uses for the
owner key via `BarnardCoreKeyManager.loadOrCreate`'s `storage:` argument),
or Barnard switching its own internal default away from
`BarnardUserDefaultsKeyStorage` itself. Either way, this is a scope
decision for Barnard's maintainer (直江さん), and this document does not
propose crossing KMP-002 to work around it. This matches, independently,
what `docs/specs/scan-slice2-redesign.md` §9.1 already found in 2026-07-30
when it considered deriving the owner key from `DeviceSecret`: "This is a
`BarnardCore`/SDK-level storage change... likely needs a Barnard SDK
change, which is outside this app repo's control."

**Practical framing for whoever coordinates with Barnard**: the ask is not
"please move `DeviceSecret` to Keychain for us" in the abstract — it is
concretely "please add an injectable `BarnardCoreKeyStorage` (and, for
symmetry, `BarnardCoreRandomSource`) parameter to `BarnardIdentity.init`
and `BarnardEngine.init`, mirroring the pattern `BarnardCoreKeyManager
.loadOrCreate` already exposes for consumers like beid's own owner key."
That is a small, additive, backward-compatible SDK change (a new
defaulted initializer parameter) — not a request that Barnard itself
adopt Keychain, which keeps the choice of accessibility class /
sync-or-not on beid's side, consistent with §1's scope decision living in
the app that has the product-level continuity stance, not the SDK.

### 2.3 A secondary finding: `DeviceSecret` is read on every signing call, not cached

Independent of the injection-point question, `BarnardIdentity.sign(
eventCode:bytes:)` and `.signingPublicKey(eventCode:)` both call
`getOrCreateDeviceSecret()` inline on every invocation
(`BarnardIdentity.swift:43,50` call `getOrCreateDeviceSecret()` directly;
`getOrCreateDeviceSecret()` itself, `BarnardIdentity.swift:94`, has no
memoization — it re-runs `BarnardCoreKeyManager.loadOrCreate` against
storage every time). In beid, `signWindowReport` (backed by
`identity.sign`) fires from `SensingCoordinator.closeWindow`
(`SensingCoordinator.swift:1089`) on **every ENIN window close** — the
surrounding doc comment calls this "high frequency, per the protocol
model" (`SensingCoordinator.swift:1061-1062`). `eventSigningPublicKey`
(backed by `identity.signingPublicKey`) is also called at
`SensingCoordinator.swift:768,914,1194`.

This means that if `DeviceSecret`'s storage moves to Keychain on Barnard's
side, every one of those per-window calls becomes a Keychain read, not a
`UserDefaults` read — a materially larger cost surface than the owner
key's cache-after-first-derivation pattern (§4). This document cannot fix
that (§2.2 — no beid-side hook), but it is worth surfacing explicitly as
input to the Barnard-side coordination: if Barnard implements the
injectable-storage change, Barnard should also consider caching the
derived signing key pair per `eventCode` the way beid already does for
the owner key (§4), or the per-window signing path could pick up a
Keychain round-trip on every window close. This is a finding for
Barnard's side to weigh, not a beid-side design decision this document
makes.

## 3. Design for the migration itself (owner-key seed only, per §2)

Scoped to the part beid can actually build: moving the owner-key seed's
storage from `BeidUserDefaultsKeyStorage` to a new `BeidKeychainKeyStorage`.

### 3.1 What exists today for existing installs

Any install that has already called `OwnerKeyProvider.keyPair()` at least
once has 32 bytes sitting under `UserDefaults` key `"beid.ownerKeySeed"`
(`OwnerKeyProvider.swift:29`) in plaintext. A migration must not silently
orphan that value — every `SelfProofRecord`/`BindingRecord` created before
the migration references the public key derived from it; regenerating a
fresh seed on migration would be the exact "既存の記録が指す先を失う"
failure mode `docs/specs/owner-key-seed-read-failure.md` (gh#156) was
written to prevent for the read-failure case. A Keychain migration that
carelessly drops or fails to carry over the existing seed reintroduces
that same failure mode through a different door.

### 3.2 The read-once-write-once shape

On `BeidKeychainKeyStorage.bytes(forKey:)`'s first call after the
migration ships (or, more simply, as a one-time migration step run before
`OwnerKeyProvider` is constructed):

1. Check the Keychain for an existing item under the seed's identifier. If
   present, that is now the source of truth — return it, and do not touch
   `UserDefaults` at all (this covers every call after the first migration
   has already run once).
2. If absent from the Keychain, check `UserDefaults` for the legacy key
   `"beid.ownerKeySeed"`. If present, this is a pre-migration install:
   write that exact byte sequence into the Keychain, then proceed to §3.3
   (what happens to the `UserDefaults` copy).
3. If absent from both, this is a fresh install (or a install past its
   `UserDefaults` copy already having been cleared by a prior migration
   run) — return `nil` and let `BarnardCoreKeyManager.loadOrCreate`'s
   existing generate-and-store path run exactly as it does today, except
   its `storage.setBytes` call now writes to Keychain instead of
   `UserDefaults`.

This shape requires no change to `BarnardCoreKeyManager.loadOrCreate`
itself (§4 of gh#156's spec establishes the same constraint for the
read-failure fix, and it holds here too) — the migration logic lives
entirely inside `BeidKeychainKeyStorage`'s own `bytes(forKey:)`
implementation, upstream of ever calling into Barnard.

### 3.3 What happens to the `UserDefaults` copy — three options, real tradeoffs

**Option A — clear `UserDefaults` immediately after a successful Keychain
write.**
- *For*: the whole point of migrating is to stop keeping a long-lived
  secret in plaintext `UserDefaults`. Leaving a copy there after migration
  defeats that purpose — an attacker who can read `UserDefaults` (e.g. via
  an unencrypted backup, or a jailbreak that bypasses Keychain protection
  but not file-level `UserDefaults`) still has the seed.
- *Against*: if the Keychain write fails partway (device in a locked
  state that rejects the accessibility class chosen, `errSecInteractionNotAllowed`,
  disk pressure, or any other `SecItemAdd` failure), and `UserDefaults` is
  cleared unconditionally right after, the seed is lost outright — the
  exact "destroy without preserving" failure gh#156's spec explicitly
  designed against for the read-failure case (`owner-key-seed-read-failure.md`
  §6: "quarantine-then-generate... not fail-closed... preserve, then
  proceed"). Clearing before confirming the write succeeded risks
  reintroducing that same class of bug through the migration path instead
  of the read path.

**Option B — leave `UserDefaults` as a permanent fallback, read Keychain
first.**
- *For*: maximally safe against Keychain write failures — the seed is
  never in a state where only one copy exists.
- *Against*: this is close to not migrating at all from a security
  standpoint. The plaintext copy an attacker could read from
  `UserDefaults` is exactly the thing gh#77 exists to eliminate; leaving it
  in place permanently defeats the issue's stated purpose while giving the
  appearance of having addressed it.

**Option C — clear `UserDefaults` only after confirming the Keychain write
succeeded and is independently readable back. Recommended.**
- *Mechanics*: after `SecItemAdd` (or `SecItemUpdate` if an item already
  exists) returns `errSecSuccess`, immediately issue a
  `SecItemCopyMatching` read for the same item and compare the returned
  bytes to what was just written. Only if that round-trip confirms an exact
  match does the migration clear the `UserDefaults` key
  (`UserDefaults.standard.removeObject(forKey: "beid.ownerKeySeed")`). If
  the write fails, or the read-back doesn't match, `UserDefaults` is left
  untouched and the migration is retried on the next app launch (idempotent
  — §3.2 step 2 re-runs from the same starting state, since nothing was
  cleared).
- *For*: this is exactly the discipline `owner-key-seed-read-failure.md`
  §6 already established for this codebase's one existing precedent of
  "preserve before destroy": write-then-verify-then-clear, never
  clear-then-write. It closes Option A's data-loss risk without Option B's
  permanent-fallback problem — the plaintext copy is transient (exists only
  until the next successful launch that completes the round-trip), not
  permanent.
- *Against*: slightly more code than Option A (one extra `SecItemCopyMatching`
  call), and the transient window where both copies exist is real, though
  bounded to a single migration pass rather than indefinite.

This mirrors, at the storage-adapter level, the same "preserve before
destroy" principle `owner-key-seed-read-failure.md` §6 applied to
quarantine-then-generate for read failures — not because this document is
required to reuse that spec's code, but because it is the same underlying
discipline (don't destroy the only copy of a value records already
reference until a replacement is confirmed durable) applied to a different
trigger (a one-time storage migration instead of a detected read failure).

### 3.4 Interaction with gh#156's quarantine mechanism (pending, not yet merged — §0)

`owner-key-seed-read-failure.md` §5's recommended pre-flight
(`bytes(forKey:)` distinguishing unset/wrong-type/wrong-length before
calling `loadOrCreate`, quarantining anything invalid under a
`"beid.ownerKeySeed.quarantine.<timestamp>-<uuid>"` `UserDefaults` key) is
designed entirely inside `BeidUserDefaultsKeyStorage`. Two landing orders
are possible, and this design should not assume either:

- **If #156 lands first**, then by the time a Keychain migration is built,
  `BeidUserDefaultsKeyStorage.bytes(forKey:)` already contains the
  read-failure pre-flight. A `BeidKeychainKeyStorage` migration reading the
  legacy `UserDefaults` value (§3.2 step 2) should read it through that
  same pre-flight path (i.e., call the existing, already-hardened
  `BeidUserDefaultsKeyStorage.bytes(forKey:)` rather than a raw
  `defaults.data(forKey:)`), so a pre-existing corrupt/invalid seed is
  quarantined exactly as #156 already specifies, instead of a fresh
  32-byte value being copied into the Keychain unquarantined. Concretely:
  the migration constructs a `BeidUserDefaultsKeyStorage` and calls its
  `bytes(forKey:)`, rather than reading `UserDefaults` directly — reusing
  #156's already-approved logic instead of re-deriving it.
- **If the Keychain migration lands first** (before #156 merges), the
  migration's own read of the legacy `UserDefaults` value should use the
  same `object(forKey:)`-before-`data(forKey:)` pattern
  `owner-key-seed-read-failure.md` §5 specifies (distinguishing "absent"
  from "present but wrong shape") rather than a bare `data(forKey:)` read,
  so a later #156 merge doesn't have to reconcile two different
  read-failure-handling code paths that grew independently. Whoever
  implements the Keychain migration should re-read #156's current status
  before starting (§0) and prefer landing #156 first if both are close to
  ready, since #156's pre-flight logic is small and self-contained and
  makes the migration's own read strictly safer.

Either way, this document's recommendation is: **the Keychain migration's
one-time legacy-value read must not silently copy an invalid seed into the
Keychain.** Whether that protection comes from calling #156's already-built
pre-flight (if merged) or from a minimal inline version of the same
`object(forKey:)`/`== 32`-length check (if #156 hasn't merged yet), the
invariant is the same and should not regress either way.

## 4. `OwnerKeyProvider`'s caching policy — the PM's explicit review requirement

### 4.1 Current behavior, confirmed from code

`OwnerKeyProvider.keyPair()` (`OwnerKeyProvider.swift:88-102`) **caches the
full derived key pair — including the owner private key — in memory for the
lifetime of the `OwnerKeyProvider` instance**:

```swift
private var cachedKeyPair: BarnardCoreSigningKeyPair?
...
private func keyPair() -> BarnardCoreSigningKeyPair {
  if let cachedKeyPair { return cachedKeyPair }
  let seed = BarnardCoreKeyManager.loadOrCreate(...)
  let keyPair = BarnardCoreSigning.deriveOwnerKeyPair(accountSecret: seed)
  cachedKeyPair = keyPair
  return keyPair
}
```

The doc comment directly above the field (`OwnerKeyProvider.swift:33-36`)
states the intent: "The owner key is stable for the device's lifetime
(until reinstall) — cached after first derivation so repeated
`SensingCoordinator.beginEventFound` calls... don't re-run secp256k1 scalar
multiplication every time."

### 4.2 How long that cache actually lives, traced through instantiation

`OwnerKeyProvider` is constructed once, as a `private let` inside
`BarnardSensingCryptography` (`SensingCryptography.swift:61`).
`BarnardSensingCryptography` is itself constructed exactly once in
production, inside `SensingCoordinator`'s convenience initializer
(`SensingCoordinator.swift:388`). `SensingCoordinator` is constructed
exactly once, as `let sensingCoordinator = SensingCoordinator()` on
`AppCoordinator` (`AppCoordinator.swift:22`). `AppCoordinator` is
constructed exactly once in production, as
`@StateObject private var coordinator = AppCoordinator()` in `BeidApp.swift:8`
(every other `AppCoordinator()` call site in the codebase is inside a
SwiftUI `#Preview` provider, not a production path). **The cache therefore
lives for the entire app process lifetime** — the owner private key is
derived from storage at most once per app launch, and every subsequent
`publicKeyCompressed()`/`signSelfProof`/`signWalletAcknowledgement` call for
the rest of that process's life reuses the same in-memory key pair, never
touching storage again.

### 4.3 Why this specific cache is the crux of the issue — gh#77's own comment

`gh issue view 77 --repo thegreeting/beid --comments` surfaces a comment
(not mentioned in the issue body itself, and not summarized in the SubPM's
briefing — read directly per the method note) that names this exact
tension precisely:

> gh#88 サブスライス A(PR #90)で `OwnerKeyProvider` のキャッシュを公開鍵の
> みから鍵ペア全体に広げました。**owner 秘密鍵がインスタンスの生存期間中
> メモリに常駐します**。現時点ではこれを許容しています。owner key のシー
> ドは既に平文の `UserDefaults` にあり、プロセスメモリを読める攻撃者は
> シードを直接取ってきて鍵を再導出できるため、キャッシュの有無で脅威モデ
> ルが実質変わらないからです。**ただし本 issue で DeviceSecret / owner key
> シードを Keychain へ移した時点で、この判断は成立しなくなります。**
> Keychain 化の目的は長寿命の平文秘密をプロセスメモリに置かないことなの
> で、その状態でキャッシュを残すと最も弱い環がキャッシュ側に移ります。

This is exactly right, and matches §4.2's independent trace: the current
"cache the whole key pair for the process lifetime" decision was
explicitly justified by "the seed is already sitting in plaintext
`UserDefaults`, so an in-memory cache doesn't materially worsen the threat
model — an attacker who can read process memory can already read the seed
from disk." **Migrating the seed to Keychain removes that justification.**
Once the seed itself is no longer trivially readable from disk, a
process-lifetime in-memory cache of the derived private key becomes the
single weakest point in the whole design — worse than the (now-hardened)
storage, because it has no OS-level access control, no encryption at rest,
and is reachable by any memory-read primitive (jailbreak tooling, a
debugger attached to a Release-signed build via developer mode, a future
memory-disclosure bug elsewhere in the process) without ever touching the
Keychain's own protections at all.

### 4.4 Recommendation: the Keychain migration must revisit this cache, not ship it unchanged

**Do not ship a Keychain migration that leaves `cachedKeyPair` caching the
private key for the process lifetime unchanged.** Two options, real
tradeoffs:

**Option A — remove the cache; re-derive from Keychain on every call
(matching `BarnardIdentity`'s own no-cache pattern for `DeviceSecret`,
§2.3).**
- *For*: the private key genuinely never sits in memory longer than a
  single call's stack frame. Structurally the strongest option, and
  consistent with how Barnard's own `DeviceSecret`-derived signing already
  behaves (no beid-side inconsistency introduced).
- *Against*: `keyPair()` is called on every `publicKeyCompressed()`,
  `signSelfProof`, and `signWalletAcknowledgement` invocation — including
  `beginEventFound`'s `ownerPublicKey()` call once per event
  (`SensingCoordinator.swift:769`) and the self-proof/wallet-ack signing
  calls during the entrance ceremony and binding flow
  (`SensingCoordinator.swift:857,902,1197`). Unlike `DeviceSecret`'s
  per-ENIN-window signing (§2.3, genuinely "high frequency"), every one of
  the owner-key call sites is tied to an already-infrequent,
  already-user-visible event (event confirmation, one-time entrance
  ceremony, one binding per event) — none of them are in the hot,
  silent, per-window signing path. A Keychain read using
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (§1) with no
  `SecAccessControl`/biometry flags does not prompt the user and typically
  completes in low single-digit milliseconds — imperceptible at this call
  frequency, unlike a biometry-gated read would be.
- **Bounded scalar-multiplication cost**: removing the cache also means
  `BarnardCoreSigning.deriveOwnerKeyPair` (a secp256k1 scalar
  multiplication) re-runs on every call instead of once per process. This
  is the cost the existing doc comment (`OwnerKeyProvider.swift:33-36`)
  says the cache exists to avoid. At the owner key's actual call frequency
  (event-scoped, not window-scoped — see above), this is a small, bounded
  number of extra scalar multiplications per session, not a hot-path
  regression.

**Option B — keep a cache, but shrink its lifetime and its contents
(explicit expiry, or public-key-only caching with the private key
re-derived per signing call).**
- *For*: preserves some of the performance benefit the original cache was
  added for, while narrowing the exposure window.
- *Against*: this is strictly more complex than Option A for a benefit
  Option A's analysis (above) suggests is not needed at this call
  frequency — the "For"/"Against" of the original PR #90 change
  (broadening from public-key-only to full-key-pair caching) was itself
  justified by *convenience*, not by a measured performance requirement
  documented anywhere; the doc comment's own framing ("don't re-run
  secp256k1 scalar multiplication every time") does not cite a measured
  cost, only a general "why redo work" intuition. Reintroducing complexity
  to preserve an unmeasured optimization is not obviously worth it once
  the “the plaintext seed's already exposed at rest” justification (§4.3)
  that made the simpler, riskier cache acceptable in the first place goes
  away.

**Recommendation: Option A.** Return `OwnerKeyProvider` to deriving the key
pair fresh on every call (mirroring `BarnardIdentity`'s own no-cache
pattern for `DeviceSecret`-derived keys, so beid and Barnard's two
key-derivation call patterns become consistent with each other rather than
diverging), once the seed itself is Keychain-backed. This is exactly what
the gh#77 comment (§4.3) itself suggests as one of its two options ("
`BarnardIdentity` と同じ都度導出に戻すか"). If a future profiling pass
shows this is a measurable cost at actual production call frequencies, a
narrower cache (Option B) can be reintroduced then, informed by real
numbers instead of intuition — but that is not a reason to keep today's
broad, unmeasured cache in place through a security-hardening change whose
whole point is removing the justification that made the cache low-risk.

### 4.5 Access-control level, tied to §1's scope decision

Per §1 (local-only, no iCloud sync) and per §4.4 (no biometry gate, to
preserve the "silent, unattended per-event signing" product requirement —
`DECISIONS.md` 2026-07-26 "署名方式": "報告のたびの承認往復を避けつつ"):

**Recommendation: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, with no
`SecAccessControl` object (i.e., no `.biometryAny`/`.userPresence`/
`.devicePasscode` access-control flags).**

- `...ThisDeviceOnly` directly implements §1's local-only scope decision —
  the item is excluded from iCloud Keychain sync and from device-to-device
  migration via encrypted backup restore, matching D1's "no continuity"
  stance structurally, not just by omission.
- `...WhenUnlocked` (rather than `...Always`, a deprecated class) requires
  the device to be unlocked for access but does **not** require a Face
  ID/Touch ID/passcode prompt at read time — that only happens when a
  `SecAccessControl` object with biometry/passcode flags is attached to the
  item, which this recommendation deliberately omits. This matters because
  every owner-key call site (§4.4) is reached from `SensingCoordinator`'s
  BLE-driven, backgroundable event/window handling — a Face ID prompt
  firing from a background BLE callback would either silently fail (no UI
  context to prompt into) or require restructuring the whole call chain to
  be async and interruptible, which no other part of `SensingCryptography`
  is today. Add a biometry gate here would very likely have to force that
  refactor as a side effect of a "just add Keychain" change — worth naming
  explicitly as a reason this document steers away from it.
- If iCloud sync is added in a future slice (§1's flagged tension),
  `kSecAttrSynchronizable = true` combined with a non-`ThisDeviceOnly`
  accessibility class (e.g. `kSecAttrAccessibleAfterFirstUnlock`, the
  synchronizable-compatible equivalent) would be the change — a distinct
  future decision, not something this document resolves now.

## 5. Acceptance criteria (for whoever implements this later)

1. `BeidUserDefaultsKeyStorage` is replaced by a new `BeidKeychainKeyStorage`
   (or equivalent name) conforming to `BarnardCoreKeyStorage`, used as
   `OwnerKeyProvider`'s default `keyStorage` argument
   (`OwnerKeyProvider.swift:40`). `BarnardCoreKeyStorage`'s protocol shape
   is unchanged (§2.1).
2. The new storage type uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
   with no `SecAccessControl`/biometry flags (§4.5), and does not enable
   `kSecAttrSynchronizable` (§1).
3. An install with a pre-existing `UserDefaults` seed (`"beid.ownerKeySeed"`)
   migrates that exact seed into the Keychain — verified by a test asserting
   the post-migration owner public key equals the pre-migration one (i.e.
   existing `SelfProofRecord`/`BindingRecord` entries remain valid against
   the migrated key, per §3.1).
4. The `UserDefaults` legacy value is cleared only after a confirmed,
   read-back-verified Keychain write (§3.3 Option C) — a test simulating a
   Keychain write failure asserts the `UserDefaults` copy is still present
   and readable afterward (no data loss on partial failure).
5. The migration is idempotent: running it a second time (e.g. on the next
   app launch, with the Keychain item already present) is a no-op that
   does not re-write, re-verify, or touch `UserDefaults` again.
6. A fresh install (no `UserDefaults` seed, no Keychain item) generates a
   fresh 32-byte seed directly into the Keychain via the existing
   `BarnardCoreKeyManager.loadOrCreate` generate-and-store path, unchanged
   (§3.2 step 3).
7. `OwnerKeyProvider.cachedKeyPair`'s process-lifetime full-key-pair cache
   is removed (§4.4, Option A) — a test asserts two sequential calls to
   `keyPair()` (or a testable equivalent) each independently read from the
   injected storage rather than reusing a previous in-memory value (e.g. by
   asserting a call-counting fake storage's `bytes(forKey:)` is invoked
   more than once across multiple `keyPair()`-triggering calls).
8. Existing `OwnerKeyProviderTests`'s golden-vector tests
   (`testPublicKeyCompressedMatchesBarnardPinnedZeroSeedVector`,
   `...SequentialSeedVector`) continue to pass unmodified against the new
   storage type (no regression to the derivation logic itself, only to
   where bytes are read from).
9. If gh#156 has landed by the time this is implemented, the migration's
   legacy-value read goes through `BeidUserDefaultsKeyStorage`'s (already
   hardened) `bytes(forKey:)` rather than a raw `UserDefaults` call (§3.4).
   If gh#156 has not landed, the migration's own legacy read distinguishes
   absent-vs-wrong-shape using the same `object(forKey:)`-before-
   `data(forKey:)` pattern, so a later #156 merge does not have to
   reconcile two independently-grown read-failure paths (§3.4).
10. This document's finding that the `DeviceSecret` portion of gh#77 is not
    actionable by beid alone (§2.2) is communicated to whoever owns
    coordination with Barnard (直江さん) before any Barnard-side work is
    requested or assumed — this document does not itself constitute that
    coordination.

## 6. Explicitly out of scope

- **Cross-event/cross-reinstall owner-key identity continuity as a product
  decision.** `DECISIONS.md` 2026-07-30 "D1" already decided against this
  for v1, and this document does not reopen it (§1). This document is
  about where the owner-key seed's bytes are stored more securely on the
  *current* device, not about giving the product a continuity guarantee it
  does not have today. §1 names the tension (iCloud sync would grant
  continuity as a side effect) explicitly rather than deciding it here.
- **`DeviceSecret`'s actual storage migration.** Per §2.2, this is not
  actionable from beid's side without a Barnard SDK change. This document
  states the finding and the concrete shape of the ask for Barnard's side
  (§2.2's closing paragraph); it does not design that SDK change itself,
  since that is Barnard's design surface, not beid's.
- **`BarnardCoreKeyManager.loadOrCreate`'s or `BarnardCoreSigning
  .deriveOwnerKeyPair`'s internals.** Both remain untouched (§2.1) — this
  design only changes which `BarnardCoreKeyStorage` implementation beid
  passes in.
- **A biometric/passcode gate on the owner key.** Explicitly recommended
  against in §4.5, to preserve the existing silent/unattended per-event
  signing requirement — not an oversight, a stated tradeoff.
- **iCloud Keychain sync itself.** Recommended against for this document's
  scope (§1); left as a clearly-separable future addition to the same
  Keychain item if owner-key continuity is ever prioritized as its own
  product decision.
- **Implementation.** This document is a design only, per the task's
  explicit instruction. No `BeidKeychainKeyStorage` code, no
  `OwnerKeyProvider` cache-removal code, and no migration code were
  written to produce it.
