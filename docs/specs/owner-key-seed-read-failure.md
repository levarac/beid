# Spec — Owner-key seed read-failure vs. unset (gh#156)

Status: **DRAFT — pending SubPM/PM/user ratification.** No code has been
written. Per `DECISIONS.md`'s 2026-08-03 "コード先行禁止" entry, none may be
written against this spec until it is approved. All four decision points
gh#156 lists under "決めるべきこと" are resolved below with a stated
recommendation and a real for/against each (§5–§8); none are left as an
open blocking question the way `session-end-finalization.md` §7.1 was —
this document's only open item is ratification itself.

Author: Worker `a-20260809-006`, for SubPM `a-20260809-001`.

**Method note**: no product code was written or edited to produce this
document. Every factual claim below is sourced from one of: `ios/Beid`
source read directly this session (`OwnerKeyProvider.swift`,
`CorruptStoreQuarantine.swift`, `SensingCoordinator.swift`,
`SensingCryptography.swift`, `SelfProofStore.swift`,
`BindingRecordStore.swift`, `SelfProofRecord.swift`, `BindingRecord.swift`,
`OwnerKeyProviderTests.swift`), the pinned Barnard SDK source cloned fresh
at the exact revision beid's `Package.resolved` points to
(`levarac/barnard` `57a8a7df7f4b2078150eabff4c06a46cfb2aae0f`, tag `0.3.0`
— confirmed against
`ios/Beid.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved:5-11`;
no local DerivedData SwiftPM checkout existed on this machine, so the
revision was fetched via `git clone`+`git checkout` into the scratchpad
instead — same revision, verified by `git rev-parse HEAD` after checkout),
`DECISIONS.md` read in full directly (not paraphrased), gh#156's actual
issue body (`gh issue view 156 --repo thegreeting/beid`), and `AGENTS.md`
read directly for KMP-002 and the Android current-state paragraph. One
claim (`UserDefaults.data(forKey:)`'s type-mismatch-returns-nil contract)
is Apple's documented Foundation API behavior, not something read from
source or executed this session — flagged explicitly here rather than
stated as independently verified, same caveat style
`session-end-finalization.md` §2.3 used for Apple lifecycle facts it could
not read from source either.

Builds on: `docs/specs/session-end-finalization.md` (rigor/structure
model, cited per-section below); the `CorruptStoreQuarantine` mechanism
(`ios/Beid/Persistence/CorruptStoreQuarantine.swift`, added by PR #157,
closes #135) — this spec adapts its *principle*, not its file-rename
*mechanism*, to a `UserDefaults`-shaped store (§6). Per AGENTS.md: "Build
on it; do not redo it."

Tracks: gh#156 ("オーナー鍵の種が読めないと黙って作り直され、既存の
self-proof と binding が孤児になる").

## 1. Scope

**IN**: confirming gh#156's own claims against the actual pinned code
rather than trusting the issue text (§3); resolving all four of its
decision points with recommendation + real tradeoff (§5–§8); a startup
detectability mechanism sketch (§8) built from state that already exists
on disk today, requiring no new persisted field; acceptance criteria
(§9); the both-OS note (§10); explicit out-of-scope items (§11).

**OUT**: cross-event/cross-reinstall owner-key continuity — this is
`DECISIONS.md`'s 2026-07-30 "D1" entry's own accepted limitation for v1,
not something this spec revisits (§2 explains the boundary precisely).
`BarnardCoreKeyManager.loadOrCreate`'s first-generation race condition,
tracked independently upstream at `levarac/barnard#125` — gh#156's own
text flags this as unrelated and this spec does not touch it or wait on
it. Designing the UI/UX response to a detected regeneration — §8 sketches
only the state needed to *check* for one, per the task's explicit
instruction that the UI/UX response is out of scope here.

## 2. What D1 already settled vs. what #156 is actually about

`DECISIONS.md`'s 2026-07-30 entry "D1 owner key 確定 + D2 census 拡張は
先送り" states the owner key "is beid(アプリ)側で生成・保持する" and, in
its own trailing "残論点" note, names as **non-blocking, deferred to a
Slice-2 spec**: "owner key の機種変・紛失時の継続性(DeviceSecret 派生 or
独立生成+iCloud バックアップ)". `OwnerKeyProvider.swift:10-14`'s own doc
comment restates this identically: "no continuity for v1 — the key
regenerates per device/reinstall." **This spec does not reopen that.** A
fresh install or a lost device legitimately having no prior owner key, and
therefore generating a fresh one on first use, is D1's accepted v1
behavior and out of scope here.

What gh#156 identifies as **not** covered by D1 is narrower: **the seed
silently regenerating mid-use, on the same install, after records that
reference the old key already exist.** Concretely: a device that has
already produced one or more `SelfProofRecord`/`BindingRecord` entries
under owner public key `P1`, then — without any reinstall, without the
user doing anything — has its stored seed read as unreadable/invalid by
`keyPair()`'s next call, silently regenerates to a new seed, and starts
signing under a different owner public key `P2`. Every existing record
still says `P1`; nothing currently observes or reports the swap. This is
the "利用途中で黙って作り直され、既存の記録が指す先を失う" case gh#156's
own body names, and it is what §5–§9 below resolve.

## 3. Current code, read directly

### 3.1 The three read outcomes at the storage boundary

`BeidUserDefaultsKeyStorage` (`ios/Beid/Sensing/OwnerKeyProvider.swift:108-122`):

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

`UserDefaults.data(forKey:)` is Apple's type-safe accessor: it returns
`nil` both when no value is stored under the key **and** when a value is
stored but is not a `Data`/`NSData` object (documented Foundation
behavior — not verified by running code this session, per the method
note above). This directly confirms gh#156's claim: the three cases the
task asked to distinguish behave as follows once traced through this
exact function —

- **(a) never stored** → `defaults.data(forKey:)` → `nil` → `bytes(forKey:)`
  returns `nil`. Correct, unambiguous "unset."
- **(b) stored, wrong type** (e.g. a `String`, or any non-`Data`
  property-list value ever ends up under `"beid.ownerKeySeed"`) →
  `defaults.data(forKey:)` → `nil` (Apple's own type-check fails) →
  `bytes(forKey:)` returns `nil`. **Indistinguishable from (a) at this
  layer.**
- **(c) stored, correct type (`Data`), but `< 32` bytes** →
  `defaults.data(forKey:)` returns the (short) `Data` → `bytes(forKey:)`
  returns `Array(shortData)`, a **non-nil** `[UInt8]` of count `< 32`.
  Distinguishable from (a)/(b) *at this layer* (it is not `nil`) — but,
  per §3.2 below, the distinction is lost one call frame up, inside
  Barnard's own `loadOrCreate`.

So today: (a) and (b) collapse to the same signal (`nil`) and are
genuinely unrecoverable as different cases once inside
`bytes(forKey:)` — confirming gh#156's claim precisely. (c) is
distinguishable from (a)/(b) at the `bytes(forKey:)` return-value level,
but nothing currently reads that distinction before the value is
discarded (§3.2).

### 3.2 `BarnardCoreKeyManager.loadOrCreate` — confirmed Barnard-owned, confirmed `[UInt8]?`-only boundary

Read directly from the pinned revision (`levarac/barnard`
`57a8a7df7f4b2078150eabff4c06a46cfb2aae0f`, tag `0.3.0`,
`packages/swift/barnard/Sources/BarnardCore/BarnardCoreCrypto.swift:47-61`):

```swift
public protocol BarnardCoreKeyStorage {
  func bytes(forKey key: String) -> [UInt8]?
  func setBytes(_ bytes: [UInt8], forKey key: String)
}

public enum BarnardCoreKeyManager {
  public static func loadOrCreate(
    key: String,
    minimumByteCount: Int,
    generatedByteCount: Int,
    storage: any BarnardCoreKeyStorage,
    randomSource: any BarnardCoreRandomSource
  ) -> [UInt8] {
    if let existing = storage.bytes(forKey: key), existing.count >= minimumByteCount {
      return existing
    }
    let generated = randomSource.randomBytes(count: generatedByteCount)
    storage.setBytes(generated, forKey: key)
    return generated
  }
}
```

Two things confirmed directly, not trusted from the issue text:

1. **This is Barnard-owned code** (`BarnardCore` module, part of the
   `Barnard` SwiftPM package beid consumes as a pinned dependency,
   `ios/project.yml:52-55`) — matching gh#156's own claim "この関数は
   Barnard 側の所有（KMP-002）". Per `AGENTS.md:86-90` (KMP-002): "Barnard
   remains native on both platforms... `shared/` may check only boundary
   shape." This spec's recommendation therefore must not, and does not,
   propose any change to this function or to `BarnardCoreKeyStorage`'s
   protocol shape.
2. **The boundary really is `[UInt8]?` with no richer signal.**
   `BarnardCoreKeyStorage.bytes(forKey:)` is declared to return a plain
   optional — not throwing, not a `Result`, not a tri-state enum. Beid
   structurally cannot signal "read failed, distinct from unset" through
   this protocol as written. This settles the task's open question from
   research step 4: there is no richer shape already available at the
   boundary that beid is failing to use — the boundary is genuinely
   this narrow. **Any fix must therefore happen entirely on beid's side
   of the port, before `loadOrCreate` is ever called**, so that by the
   time Barnard's function runs, it only ever sees a legitimately-unset
   key — never an ambiguous one.

A second, independent fact from the same read, not raised by gh#156
itself: `loadOrCreate`'s own validity check is `existing.count >=
minimumByteCount` (line 55, `>=`, not `==`). `OwnerKeyProvider.keyPair()`
(`ios/Beid/Sensing/OwnerKeyProvider.swift:92-99`) calls this with
`minimumByteCount: 32`, then immediately feeds whatever `loadOrCreate`
returns into `BarnardCoreSigning.deriveOwnerKeyPair(accountSecret:)`. That
function, read from the same pinned revision
(`packages/swift/barnard/Sources/BarnardCore/BarnardCoreSigning.swift:74-77`):

```swift
public static func deriveOwnerKeyPair(
  accountSecret: [UInt8]
) -> BarnardCoreSigningKeyPair {
  precondition(accountSecret.count == 32, "accountSecret must be 32 bytes")
  ...
```

**`deriveOwnerKeyPair` requires exactly 32 bytes and traps (crashes) on
anything else.** `loadOrCreate`'s `>= 32` check is not sufficient to
protect that precondition: a stored value of, say, 40 bytes passes
`loadOrCreate`'s check (`40 >= 32`), is returned unmodified as "valid,"
and is then handed to `deriveOwnerKeyPair`, which crashes. This is a
distinct latent bug from the one gh#156's own text frames ("32 バイト未満
の値を「無効」として作り直す判定が妥当か" — the issue only considers the
too-short direction). §7 folds this into decision 3's answer: the
validity test beid's own pre-flight must use is `== 32`, not `>= 32`,
because relying on Barnard's own `>= minimumByteCount` check is
insufficient to prevent a crash beid's own next call introduces.

### 3.3 `CorruptStoreQuarantine`'s principle, and why its literal mechanism doesn't transfer

`CorruptStoreQuarantine.swift:1-93`'s doc comment states its own
mechanism precisely: on a decode failure, "the bytes that failed to
decode are moved to a timestamped sibling name before anything can
overwrite them, and the read continues as an empty collection." Its
`resolve(loadFailure:fileURL:storeDescription:now:)` performs a
`FileManager.moveItem(at:to:)` to a new `URL` with a `corrupt-<ms>-<uuid>`
suffix, returning `.quarantined(URL)` on success or `.unpreserved(Error)`
if even the move fails (in which case the store suspends writes rather
than risk destroying unpreserved bytes — see the `Outcome` enum's own doc
comments, lines 23-47).

This literal mechanism is file-shaped: it depends on `FileManager`,
paths, and file renames. `UserDefaults` has no directly equivalent
primitive — there is no "rename this key" operation. But the *principle*
— preserve the existing bytes at a new, inspectable location before the
canonical location can be overwritten, then let the normal path proceed
as if nothing had been there — transfers cleanly, because
`UserDefaults.set(_:forKey:)` accepts `Any?` for any property-list-
compatible value. This means beid does not need to know the *concrete*
type of whatever is stored under `"beid.ownerKeySeed"` to relocate it: it
can read the raw value with `UserDefaults.object(forKey:)` (returns
`Any?`, distinguishing "absent" from "present, any type" — the exact
signal `data(forKey:)` throws away, §3.1) and, if present, copy that same
`Any` value verbatim to a new key (e.g.
`"beid.ownerKeySeed.quarantine.<timestamp>-<uuid>"`) before clearing
(`removeObject(forKey:)`) the original key. One generic operation covers
both failure shapes (§3.1's case (b) wrong-type and case (c)
too-short-or-too-long `Data`) without needing type-specific branches to
preserve each — §6 specifies this precisely.

### 3.4 Existing tests near `OwnerKeyProvider`

`OwnerKeyProviderTests.swift:1-67` is entirely golden-vector conformance
(`testPublicKeyCompressedMatchesBarnardPinnedZeroSeedVector`,
`...SequentialSeedVector`) using a private `FixedSeedKeyStorage` fake
(lines 45-53) that always returns a fixed, valid 32-byte seed and a
`NeverCalledRandomSource` that `XCTFail`s if invoked — i.e. today's tests
only ever exercise the "seed already present and valid" path. There is no
existing test that exercises `bytes(forKey:)` returning `nil`, a
wrong-typed stored value, or a too-short/too-long stored value at all.
Any new regression test for this spec extends this file with fakes for
those three shapes; §9's acceptance criteria are written to be directly
testable against fakes of this same shape (conforming to
`BarnardCoreKeyStorage`, or to whatever narrow beid-only interface §6
introduces).

### 3.5 State already on disk that a detection mechanism can reuse

`SelfProofRecord` (`ios/Beid/Persistence/SelfProofRecord.swift:18-34`)
already stores `ownerPublicKeyHex: String` (line 30) — "Compressed
secp256k1 owner public key, hex-encoded" — set once, at record-creation
time, from whatever `OwnerKeyProvider.publicKeyCompressed()` returned
during that session (`SensingCryptography.swift:67-69`,
`ownerPublicKey()` forwards directly to
`ownerKeyProvider.publicKeyCompressed()`). `BindingRecord`
(`ios/Beid/Persistence/BindingRecord.swift:26-52`) independently stores
its own `ownerPublicKeyHex: String` (line 42) at binding-completion time,
for the same reason (it is the key the wallet's signature covers). Both
stores (`SelfProofStore`, `ios/Beid/Persistence/SelfProofStore.swift:9-68`;
`BindingRecordStore`, `ios/Beid/Persistence/BindingRecordStore.swift:9-80`)
already load their full record history into memory (`records: [T]`,
`@Published`) at `init`, unconditionally. **No new field on either record
type, and no new store, is required for §8's detection mechanism** — the
correlating state already exists precisely because both record types were
already designed to be independently self-describing.

## 4. What this spec must not require

Consistent with `session-end-finalization.md` §5's convention of stating
this explicitly: this spec's recommendation must not require changing
`BarnardCoreKeyStorage`'s protocol shape, `BarnardCoreKeyManager
.loadOrCreate`'s signature or body, `BarnardCoreSigning
.deriveOwnerKeyPair`'s precondition, or `SelfProofRecord`/`BindingRecord`'s
`Codable` shape (any of which would either cross KMP-002 into Barnard's
own package, or touch an already-shipped, tested on-disk format). §6-§8
below satisfy all of these constraints; each recommendation states which
constraint it depends on not violating.

## 5. Decision 1 — should read-failure be distinguished from unset?

**Recommendation: yes.** The distinction is only recoverable on beid's own
side of the `BarnardCoreKeyStorage` boundary, before `loadOrCreate` is
called (§3.2) — so the fix is a pre-flight check inside beid's own
`BeidUserDefaultsKeyStorage.bytes(forKey:)` (or a thin beid-owned wrapper
around it), reading `UserDefaults.object(forKey:)` first to recover the
"absent vs. present-with-any-type" distinction `data(forKey:)` throws
away, before delegating to the existing `data(forKey:)`-based path for
the success case. Concretely (illustrative — exact structuring is an
implementation detail, not a design decision):

```swift
func bytes(forKey key: String) -> [UInt8]? {
  guard defaults.object(forKey: key) != nil else { return nil }     // (a) truly unset
  guard let data = defaults.data(forKey: key), data.count == 32 else {
    quarantineAndClear(key: key)                                    // (b)/(c): present but invalid
    return nil
  }
  return Array(data)                                                // valid
}
```

(`quarantineAndClear` is §6's mechanism; the `== 32` threshold, not
`>= 32`, is §7's finding.) After this runs, `loadOrCreate` sees a
genuinely, definitionally unset key in every failure case — it never
receives an ambiguous `nil` again, because beid has already resolved the
ambiguity on its own side before calling it.

- **For**: the only place structurally capable of making this
  distinction, given `[UInt8]?`'s confirmed lack of richer signal (§3.2)
  — doing it here requires no Barnard change and stays inside KMP-002.
  Reuses the exact `object(forKey:)` vs. `data(forKey:)` pairing Apple's
  own API already provides for this — no bespoke type-introspection code.
- **Against**: two separate invalidity shapes (wrong type; right type,
  wrong length) must both funnel through one pre-flight check rather than
  getting it for free the way `JSONDecoder`'s single `throws` gives the
  file stores one uniform "decode failed" signal (§3.3) — slightly more
  bespoke code than the file-store precedent, though still a handful of
  lines, not a new subsystem.

## 6. Decision 2 — what happens on a distinguished read-failure?

**Recommendation: quarantine-then-generate, mirroring
`CorruptStoreQuarantine`'s already-accepted philosophy — not fail-closed.**

**Option: fail closed (don't generate, surface the failure).**
- *For*: never lets the app silently swap identity out from under
  existing records without some explicit signal being raised first; the
  strongest possible guarantee against the exact harm gh#156 describes.
- *Against — real, not dismissed*: there is no existing failure surface
  to fail into. `OwnerKeyProvider.keyPair()` is non-optional/non-throwing
  today, and every public method built on it
  (`publicKeyCompressed()`, `signSelfProof`, `signWalletAcknowledgement`)
  is called synchronously from `SensingCryptography`
  (`SensingCryptography.swift:34-54`), whose own protocol methods are
  themselves non-optional/non-throwing except where the *input* shape
  (not the key) is being validated. Making the key layer failable would
  require threading new optionality/throwing through
  `SensingCryptography`'s protocol, `BarnardSensingCryptography`, and
  `SensingCoordinator`'s recording path — a materially larger surface
  change than #156 asks for, and one with no product/UX design for what
  the user sees when it happens (explicitly out of scope per the task
  framing). It also breaks with this codebase's established posture:
  `CorruptStoreQuarantine`'s own doc comment states its stores "must
  never wedge the app" (`CorruptStoreQuarantine.swift:17`) and chose
  recover-as-empty over failing for exactly this reason. Fail-closed here
  would introduce a new, inconsistent posture for a failure mode that is
  developer/storage-corruption-triggered, not user-triggered — trading
  common-path availability for a rare-path guarantee no other store in
  this codebase makes.

**Option: quarantine-then-generate (preserve, then proceed). Recommended.**
- *Mechanics*: exactly `CorruptStoreQuarantine`'s principle (§3.3) adapted
  to `UserDefaults`: on a detected read-failure (§5), copy the raw stored
  value verbatim to a quarantine key via `UserDefaults.set(defaults
  .object(forKey: key), forKey: quarantineKey)`, then
  `defaults.removeObject(forKey: key)` so the canonical key is
  legitimately empty, then let `loadOrCreate` run its normal
  generate-and-store path on that now-genuinely-unset key.
- *For*: matches the codebase's one existing precedent for this exact
  shape of bug 1:1, per AGENTS.md's "build on it, do not redo it." No API
  surface changes anywhere else — `OwnerKeyProvider.keyPair()` stays
  non-optional, `SensingCryptography` is untouched. gh#156's own
  acceptance criteria phrase the requirement as "**黙って** 作り直されない"
  (not silently recreated) — not "never recreated" — meaning quarantine
  (which still lets regeneration happen, but makes it non-silent and
  preserved) satisfies the issue's own stated bar; §8's detectability
  mechanism is what turns "preserved" into "discoverable," closing the
  loop the fail-closed option would otherwise need a whole new UI surface
  to close.
- *Against — real, not dismissed*: this still lets a corrupted-then-
  regenerated owner key go into active use in the same session it is
  detected — there is no UI to interrupt the user, so at this spec's
  scope "detected" is informative, not preventive. That is an accepted
  cost, not an oversight: the task's own framing places designing that
  UI/UX response out of scope.

## 7. Decision 3 — is "< 32 bytes ⇒ invalid, regenerate" the right test?

**Recommendation: no — the correct beid-side test is `count == 32`, not
`count < 32` (equivalently, not Barnard's own `>= minimumByteCount`), and
whatever fails it is quarantined via §6's mechanism before being
discarded.**

Two separate findings support this, both from §3.2's direct source read:

1. **Preservation.** gh#156's own framing ("32 バイト未満の値を「無効」
   として作り直す判定が妥当か... 壊れた値を保全せずに捨てています") is
   correct as far as it goes: a too-short value is discarded with no
   record of what it was. §6's quarantine mechanism (relocate-then-clear)
   already fixes this uniformly for any invalid value, short or
   otherwise — no separate design is needed for the "too short"
   sub-case specifically.
2. **The threshold itself is wrong, independent of preservation.**
   `loadOrCreate`'s own check is `existing.count >= minimumByteCount`
   (`BarnardCoreCrypto.swift:55`) — it treats anything `≥ 32` bytes as
   valid and returns it unmodified. But `deriveOwnerKeyPair` requires
   `accountSecret.count == 32` exactly and **traps** otherwise
   (`BarnardCoreSigning.swift:77`, `precondition`). A stored value with
   more than 32 bytes — not considered at all by gh#156's own "< 32"
   framing — would pass `loadOrCreate`'s check, be returned as
   "valid," and then crash the app the moment `deriveOwnerKeyPair` runs.
   Relying on `loadOrCreate`'s `>= minimumByteCount` check is therefore
   not sufficient on its own to guarantee `keyPair()` doesn't crash;
   beid's own pre-flight (§5) must independently enforce `== 32` before
   ever calling `loadOrCreate`, since that is the actual constraint the
   very next call in the chain (`deriveOwnerKeyPair`) imposes.

Whether to change `minimumByteCount`/`generatedByteCount`'s *values*
passed to `loadOrCreate` was considered and rejected: those are Barnard's
own parameters (`BarnardCoreKeyManager.loadOrCreate`'s signature,
untouched per §4), and `32` is already correct for both — it is
`generatedByteCount`'s value that guarantees every freshly-generated seed
is exactly 32 bytes; the gap is entirely in what happens when a
*previously-stored* value fails to match that length, which is
`BeidUserDefaultsKeyStorage`'s (beid's own) responsibility to catch before
handing anything to `loadOrCreate`, not something changing Barnard's
call-site arguments could fix.

## 8. Decision 4 — should after-the-fact regeneration be detectable?

**Recommendation: yes, using two complementary signals, both built from
state that already exists or that §6 already introduces — no new
persisted field beyond §6's quarantine key.**

**Signal A — quarantine-key existence.** §6's mechanism, on any detected
read-failure, leaves a `"beid.ownerKeySeed.quarantine.<timestamp>-<uuid>"`
entry in `UserDefaults`. Its mere presence at any later point is direct,
positive evidence that a read-failure-triggered regeneration happened,
and its timestamp suffix gives an approximate *when*. This is the
strongest of the two signals but only fires for the specific case this
spec fixes (a detected, quarantined read failure) — it does not catch a
hypothetical future regeneration cause outside this fix's scope.

**Signal B — owner-public-key mismatch across existing records.** Per
§3.5, `SelfProofStore.records`/`BindingRecordStore.records` already carry
`ownerPublicKeyHex` per record, set at the time each record was created.
At app startup, after `OwnerKeyProvider`/`SelfProofStore`/
`BindingRecordStore` are all constructed (illustrative location:
`AppCoordinator`'s init path, or wherever `SensingCoordinator` first
resolves its `bindingRecordStore`/`selfProofStore`,
`SensingCoordinator.swift:143-144` — exact wiring point is an
implementation detail), compare `sensingCryptography.ownerPublicKey()`'s
current hex against the set of distinct `ownerPublicKeyHex` values already
present across both stores' `records`. Any existing record whose owner
public key differs from the currently-active one means the seed changed
since that record was created — regardless of *why* it changed, making
this signal more general than Signal A (it would also catch, for
instance, a future non-corruption regeneration cause, or app data
partially cleared by something outside this spec's scope).

Both signals are recommended together, not as alternatives: Signal A is
precise about cause and timing but narrow in coverage; Signal B is broad
in coverage but silent about *why*. Reporting both (as a small struct or
two independent optionals — exact shape is an implementation detail) lets
a future consumer distinguish "a corruption-triggered regeneration just
happened" from "the currently active key doesn't match some historical
record, for an unknown reason."

- *For*: zero new persisted fields for Signal B (reuses
  `ownerPublicKeyHex`, already written for an unrelated reason — same
  "build on it" spirit AGENTS.md asks for); Signal A falls out of §6's
  fix for free. Together they directly satisfy gh#156's acceptance
  criterion 4 ("作り直しが起きた場合に、それが検出可能であること").
- *Against*: both signals are retroactive, checked at next launch —
  a regeneration followed immediately by new records signed under the new
  key, with the app never relaunching, is only detected on the next
  relaunch. This is the same limitation `session-end-finalization.md`
  §7.1 Option B accepted for its own reconciliation gap ("if the user
  never relaunches... the gap stays open indefinitely") — a consistent
  posture for this codebase, not a new weakness introduced here.
  Signal B's comparison is `O(records)` per launch across both stores;
  at this app's current device-local-history scale this is not a
  practical concern, but is worth naming rather than silently assuming
  away for a future high-record-count device.

Reachability plumbing note: `OwnerKeyProvider` currently holds `keyStorage`
as `any BarnardCoreKeyStorage` (an existential over Barnard's own
protocol, `OwnerKeyProvider.swift:31`), which has no channel for
quarantine metadata. Exposing Signal A therefore needs one small
beid-only addition — e.g. a narrow companion type/closure `OwnerKeyProvider`
optionally consults for "did the last `keyPair()` resolution quarantine
anything," mirroring `SelfProofStore.quarantinedFileURL`/
`persistenceSuspensionReason`'s existing readable-property pattern
(`SelfProofStore.swift:13-25`) rather than inventing a new shape. Left as
an implementation detail; the state this spec requires to exist is what
matters here, not its exact Swift plumbing.

## 9. Acceptance criteria

Restating gh#156's own four checkboxes as testable conditions, plus two
additions from this spec's own findings (marked **new**):

1. **Read-failure vs. unset are distinguished.** Test: given a fake
   storage (or a real `UserDefaults` instance) with (a) nothing stored
   under the seed key, (b) a non-`Data` value stored under it, and (c) a
   `Data` value stored under it with count `≠ 32` (both `< 32` and `> 32`
   — **new**, per §7's finding), assert the three cases are
   distinguishable before `BarnardCoreKeyManager.loadOrCreate` is ever
   called — i.e. that beid's own pre-flight code path, not `loadOrCreate`,
   is what tells them apart.
2. **On read failure, the existing value is not overwritten without being
   preserved.** Test: for shapes (b) and (c) above, assert the original
   raw value is still recoverable afterward (present, verbatim, under the
   quarantine key §6 defines) and the canonical key holds a freshly
   generated 32-byte value distinct from the discarded one.
3. **A test proves the seed is not silently recreated when a wrong-typed
   value is present.** Direct restatement of gh#156's own acceptance
   criterion 3 — covered by test 1/2 above for shape (b) specifically; no
   additional test needed beyond making sure shape (b) is one of the
   cases test 1/2 exercise.
4. **Regeneration is detectable once it happens.** Test: after a
   simulated read-failure-and-regeneration, assert Signal A (quarantine
   key presence) is readable and non-nil. Separately: given a
   `SelfProofStore`/`BindingRecordStore` seeded with a record whose
   `ownerPublicKeyHex` does not match the currently active owner public
   key, assert Signal B's comparison correctly reports a mismatch; and
   given stores where every record's `ownerPublicKeyHex` matches, assert
   it reports no mismatch (no false positive).
5. **New (§7): a stored seed longer than 32 bytes is treated as invalid,
   not accepted.** Test: given a fake storage returning, e.g., a 40-byte
   value under the seed key, assert `keyPair()` does **not** crash
   (`deriveOwnerKeyPair`'s precondition is never reached with a non-32-byte
   input) and instead the value is quarantined and a fresh 32-byte seed is
   generated, exactly like the `< 32` case.
6. **New: no regression to the valid-seed path.** Test:
   `OwnerKeyProviderTests`'s existing golden-vector tests
   (`testPublicKeyCompressedMatchesBarnardPinnedZeroSeedVector`,
   `...SequentialSeedVector`) continue to pass unmodified — the pre-flight
   check must be a no-op for an already-valid, exactly-32-byte stored
   seed.

## 10. Both-OS note

**iOS-only.** `OwnerKeyProvider`/`BeidUserDefaultsKeyStorage` are iOS-only
types (`ios/Beid/Sensing/OwnerKeyProvider.swift`); no `shared/` change is
proposed anywhere in this spec (§4). Per `AGENTS.md:46-49`: "Android
currently has only the Event Join screen, and `EventJoinCoordinator` stops
at `Idle`, `RequestingPermission`, `Sensing`, or `PermissionDenied`. The
entire post-join screen flow... is absent on Android today." Android has
no owner-key/self-proof/binding code path to exhibit this bug in at all —
there is nothing to fix or touch there. This satisfies AGENTS.md's
both-OS rule by naming the actual current gap (an Android flow that does
not exist yet), not by silence.

## 11. Explicitly out of scope

- **Cross-event/cross-reinstall owner-key continuity** — `DECISIONS.md`
  2026-07-30 "D1"'s own domain, already accepted as a v1 limitation
  (§2). Not reopened by this spec.
- **`BarnardCoreKeyManager.loadOrCreate`'s first-generation race
  condition**, independently tracked and being fixed upstream at
  `levarac/barnard#125`. gh#156's own text states this issue "は
  それとは独立" (is independent of that one) and "競合の修正では解消
  しません" (the race fix does not resolve this issue). This spec does
  not touch it, does not wait on it, and its recommendation (§5–§8) does
  not depend on `#125` landing in either direction.
- **The UI/UX response to a detected regeneration** (§8's Signal A/B) —
  this spec sketches only the state needed to check for one, per the
  task's own instruction. What the app does once it knows — surface a
  warning, offer re-binding, do nothing yet — is a separate product
  decision this document does not make.
