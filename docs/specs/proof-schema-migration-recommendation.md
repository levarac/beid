# Recommendation — proof/binding/self-proof schema versioning and migration (gh#155)

Status: **RECOMMENDATION FOR PM DECISION — not a spec pending approval, and
not something this document (or SubPM/PM alone) resolves by ratifying it.**
`thegreeting/beid#155` is explicitly reserved for escalation per SubPM's own
charter ("a schema change quarantines every user's proofs and they vanish
from the screen, with no migration path. This is data migration, which the
charter reserves for escalation."). This document decides nothing on its
own. It restates gh#155's own four "決めるべきこと" against the current,
directly-read code, gives each a recommendation with a real for/against, and
stops there — the decision itself belongs above this document, per the
escalation path SubPM's charter names, not to whichever worker or PM reads
it next.

**No product code has been written or edited to produce this document.**

Author: Worker `a-20260809-026`, for SubPM `a-20260809-001`.

**Method note**: every factual claim below is sourced from one of: `ios/Beid`
source read directly this session in the
`issue-155-schema-migration` worktree at `aa19b0a` (`Models/Proof.swift`,
`Models/ProofSignature.swift`, `Persistence/CorruptStoreQuarantine.swift`,
`Persistence/ProofStore.swift`, `Persistence/BindingRecordStore.swift`,
`Persistence/SelfProofStore.swift`, `Persistence/BindingRecord.swift`,
`Persistence/SelfProofRecord.swift`, `Persistence/SelfProofCheckpointStore.swift`,
`Views/ProofSignatureControlsView.swift`, `BeidTests/ProofStoreTests.swift`,
`BeidTests/CorruptStoreQuarantineTests.swift`); `shared/src/commonMain/.../
report/UnsentWindowLedgerSnapshot.kt` read directly for the one existing
version-marker precedent in this codebase (§3.5); `git log`/`git show`
against `origin/main` for what has actually shipped and when (§10);
`gh issue view 155/135 --repo thegreeting/beid` and `gh pr view 157 --repo
thegreeting/beid` read in full, not paraphrased; `DECISIONS.md` and
`AGENTS.md` read in full directly. Three specific claims about Swift
`Codable` synthesis (§3.2, §3.3, §6.1) that gh#155's own text asserts but
does not cite code for were **independently verified this session by
compiling and running small standalone Swift programs against the local
Swift 6.3.3 toolchain** (not trusted from the issue text or from general
Codable knowledge) — the exact programs and their output are quoted where
used, so a reader can rerun them.

Builds on: `docs/specs/owner-key-seed-read-failure.md` (rigor/structure
model this document follows, and per its own §3.3, the precedent this
document's §5 adapts for the same reason — `CorruptStoreQuarantine`'s
*principle*, not its literal file-rename mechanism, transfers to a new
context); `ios/Beid/Persistence/CorruptStoreQuarantine.swift` (added by PR
#157, closes #135) — this document proposes a check placed *before*
`CorruptStoreQuarantine` runs, not a replacement for it (§9).

Tracks: gh#155 ("スキーマを変更すると、全ユーザーの証明が「破損」として隔離
され、画面から消える（移行経路が存在しない）").

## 1. Scope

**IN**: confirming gh#155's own claims against the current, directly-read
code (§2); resolving all four of its decision points with recommendation +
real tradeoff (§3–§6); a concrete migration-testing strategy (§7);
acceptance criteria restating the issue's own checkboxes as testable
conditions (§8); explicit out-of-scope items (§9); the urgency question —
whether any schema change has already shipped since PR #157 that needs
retroactive handling (§10); the both-OS note (§11).

**OUT** (see §9 for the full list and reasoning): redesigning
`CorruptStoreQuarantine`'s core file-quarantine mechanism, which remains
correct and needed for genuine corruption; implementing any of the
recommendations below; changing any store's `Codable` shape; `shared/`
migration of these stores (none of the three are in the KMP migration
inventory today — see §11).

## 2. Root cause, restated against current code

### 2.1 No schema-version marker exists in any of the three stores today

`Proof` (`ios/Beid/Models/Proof.swift:10-90`), `BindingRecord`
(`ios/Beid/Persistence/BindingRecord.swift:26-80`), and `SelfProofRecord`
(`ios/Beid/Persistence/SelfProofRecord.swift:18-60`) each persist as a bare
top-level JSON array (`[Proof]`, `[BindingRecord]`, `[SelfProofRecord]` —
confirmed at `ProofStore.swift:74`, `BindingRecordStore.swift:60`,
`SelfProofStore.swift:56`, each a direct
`JSONDecoder().decode([T].self, from: data)` call with no wrapping object).
None of the three struct definitions declares any version field. A
repository-wide search for `schemaVersion`/`formatVersion`/a bare
`"version"` field across `ios`, `shared`, and `android` turns up exactly one
hit that is not this document's own text:
`ios/Beid/Models/ProofSignature.swift:75`'s
`SignaturePayload.schemaVersion = "AttendanceProof/v1"`. That is a
different thing entirely — it is a field *inside* the wallet-signed digest
payload used once per signing attempt (`SignaturePayload`, never persisted
to disk on its own), not a marker on the on-disk store format `ProofStore`/
`BindingRecordStore`/`SelfProofStore` read and write. **Confirms gh#155's
premise precisely: none of the three persisted store formats carries any
version identifier today.**

One related, non-obvious precedent exists elsewhere in this codebase and is
worth citing because it is genuinely instructive for §3: the shared ledger
snapshot codec (`shared/src/commonMain/kotlin/org/levarac/beid/shared/
report/UnsentWindowLedgerSnapshot.kt:3`) defines
`SNAPSHOT_HEADER = "beid-ledger-snapshot\t1"`, written as the first line of
every encoded snapshot (`:27`, `append(SNAPSHOT_HEADER).append('\n')`) and
required to match exactly on read (`:124`,
`require(reader.nextLine() == SNAPSHOT_HEADER)`). This is a real precedent
for "a beid-owned persisted format that carries a version token" — but it
is a narrower precedent than it may first appear: the check is a strict
equality `require`, not a dispatch-on-version-number. A future snapshot
format bump would change this literal string and the *old* parser would
simply fail the `require` and fall into whatever failure handling
`UnsentWindowLedgerStore` already has for an unparseable snapshot (its own
quarantine-and-restart-empty path) — i.e. the token exists today as a
sanity check, not as a working migration mechanism. It is evidence that
"add a version marker" is an established pattern in this codebase, not
evidence that "read an old version and migrate it" has ever actually been
built anywhere yet.

### 2.2 `ProofSignatureState`'s Codable shape and unknown-case behavior, verified by compiling and running Swift

gh#155's text asserts "この enum は合成された `Codable` を使っているため、旧
バージョンが知らない case は復号できません." `ProofSignatureState`
(`ios/Beid/Models/ProofSignature.swift:16-27`) is:

```swift
enum ProofSignatureState: Codable, Equatable, Hashable {
  case notRequested
  case connecting
  case awaitingApproval
  case signed(SignatureRecord)
  case deferred
  case rejected
  case failed(reason: String)
}
```

— a synthesized-`Codable` enum with a mix of no-payload and associated-value
cases (not a `RawRepresentable: String` enum, which the issue's paraphrase
could also plausibly describe; confirming the exact shape matters because
the two shapes fail differently). To verify the claim directly rather than
trust the issue's paraphrase, this session compiled and ran an equivalent
enum against the local Swift 6.3.3 toolchain (`swift --version`:
`Apple Swift version 6.3.3`). First, what the synthesized encoder actually
produces for each case shape (relevant because it shows even no-payload
cases are *not* encoded as a bare string):

```
{"s":{"notRequested":{}}}
{"s":{"connecting":{}}}
{"s":{"signed":{"_0":{"signerAddress":"0xabc"}}}}
{"s":{"failed":{"reason":"nope"}}}
```

Then, decoding a single-key object whose key is a case name the type does
not declare (`{"s":{"expired":{}}}`, standing in for a hypothetical future
case such as `.expired`) against the *current* (does-not-know-`.expired`)
type:

```
decode failed as expected: DecodingError.typeMismatch: expected value of
type ProofSignatureState. Path: s. Debug description: Invalid number of
keys found, expected one.
```

Same result whether the unknown case carries a payload
(`{"s":{"expired":{"reason":"x"}}}`) or not (`{"s":{"expired":{}}}`) — both
produce the identical `DecodingError.typeMismatch`. **Confirms gh#155's
claim exactly, with the precise error shape**: an unrecognized case is not
silently ignored or defaulted by synthesis — it throws a `DecodingError`,
the same error type `CorruptStoreQuarantine.resolve`'s
`guard loadFailure is DecodingError else { ... }`
(`CorruptStoreQuarantine.swift:65`) treats as corruption. This is the exact
mechanism by which "add a case to `ProofSignatureState`" becomes
indistinguishable from "the file is corrupt" once `ProofStore.load()`'s
`try JSONDecoder().decode([Proof].self, ...)` (`ProofStore.swift:74`)
throws.

### 2.3 `Proof.init(from:)`'s actual tolerance, verified precisely — and its exact limit

`Proof.init(from:)` (`ios/Beid/Models/Proof.swift:67-77`) is hand-written,
not synthesized, specifically to add tolerance beyond what synthesis alone
gives:

```swift
signatureState = try container.decodeIfPresent(ProofSignatureState.self, forKey: .signatureState) ?? .notRequested
eventCode = try container.decodeIfPresent(String.self, forKey: .eventCode)
```

gh#155's text states this precisely: "`Proof.init(from:)` は
**`signatureState` が「無い」ことは許容しますが、「知らない case」は許容し
ません**." This session verified the exact boundary of that tolerance by
compiling and running a struct with the identical `decodeIfPresent` line
against two inputs:

- Key entirely absent (`{"id":"abc"}`): decodes successfully,
  `signatureState` becomes `.notRequested` — this is the case
  `decodeIfPresent` is documented and designed for (`Optional<Decodable>`'s
  `decodeIfPresent` checks key-presence/`null` first, and only calls
  through to the underlying `decode` when the key is genuinely present with
  a non-null value).
- Key present, but its value is an unrecognized case
  (`{"id":"abc","signatureState":{"expired":{}}}`): **decode fails**, same
  `DecodingError.typeMismatch` as §2.2 — `decodeIfPresent` does not, and by
  its documented contract cannot, catch a decode failure of a *present*
  key's value; it only substitutes a default when the key is *absent* or
  explicitly `null`. This is easy to get backwards by reading the property
  name alone (`decodeIfPresent` sounds broader than it is), so it is
  verified here rather than assumed.

**This precisely locates the actual gap**: `Proof`'s existing custom
decoder already solves "a field that didn't used to exist" (both
`signatureState` and, as of PR #174/gh#137, `eventCode` — see §10) but does
nothing for, and cannot by construction do anything for, "a field that
exists but whose *value* has grown a shape this build doesn't recognize." A
new `ProofSignatureState` case falls squarely in the second category, not
the first — no amount of restructuring `decodeIfPresent` calls fixes it,
because the failure happens one level down, inside
`ProofSignatureState.init(from:)` itself, which `Proof.init(from:)` never
gets a chance to intervene in.

### 2.4 Blast radius: one unrecognized record fails the whole file, for all three stores

Because each store's `load()` decodes the *entire array* in one call
(`ProofStore.swift:74`, `BindingRecordStore.swift:60`,
`SelfProofStore.swift:56`), a single element anywhere in a
potentially-years-old `proofs.json`/`binding-records-v2.json`/
`self-proofs.json` file failing to decode fails the array decode as a
whole. `CorruptStoreQuarantine.resolve` then quarantines the *entire file*
(`CorruptStoreQuarantine.swift:59-93`) — every other, perfectly-decodable
proof in that file is quarantined alongside the one that triggered it. This
is the concrete mechanism behind gh#155's "証明が全部消えた" framing: it is
not a per-record loss, it is whole-file, because these three stores have no
per-element failure isolation today.

### 2.5 `BindingRecord`/`SelfProofRecord` have no custom decoder at all

Unlike `Proof`, neither `BindingRecord` (`ios/Beid/Persistence/
BindingRecord.swift:26-80`) nor `SelfProofRecord`
(`ios/Beid/Persistence/SelfProofRecord.swift:18-60`) declares
`CodingKeys` or `init(from:)`/`encode(to:)` — both rely entirely on
synthesized `Codable`. Neither has any tolerated-missing-field precedent
today (unlike `Proof.signatureState`/`Proof.eventCode`). Confirmed
empirically as part of §2.2's Swift check: for a synthesized decoder, a
struct property that is genuinely `Optional<T>`-typed *is* decoded via an
implicit `decodeIfPresent` (a missing key decodes to `nil` with no error) —
so an *additive optional field* on either type would, if it were added
today, already tolerate old files exactly the way `Proof.eventCode` does.
But neither struct has any optional field today (every field on both is
non-optional), and neither has ever needed this tolerance yet, so this is
an unexercised, unverified-in-this-codebase capability rather than an
established pattern the way `Proof`'s two `decodeIfPresent` fields are.

## 3. Decision 1 — how should each store carry a schema-version identifier?

**Recommendation: a top-level JSON envelope object
(`{"schemaVersion": <Int>, "records": [...]}`) replacing today's bare
top-level array, with the bootstrap rule that a file with no such envelope
— i.e. today's actual shipped shape, a bare array — is implicitly version
0.** One version field per *file*, not per record (justified below), and
one field per store (`ProofStore`/`BindingRecordStore`/`SelfProofStore`
each version independently — they already have independent files and
independent schemas, and nothing links their version numbers together).

**Why file-level, not per-record**: all three stores fully re-serialize
their *entire* in-memory array on every `save()`
(`ProofStore.swift:118`/`BindingRecordStore.swift:77`/
`SelfProofStore.swift:73`, each a single `JSONEncoder().encode(records)`
over the whole array). This means the moment any single record is
added or mutated and the store saves, *every* record in that file gets
re-encoded under whatever the currently-running build's `Codable`
conformance produces — there is no way for two records inside the same
saved file to be written under two different code-shapes, because the
write path has no per-record memory of "what shape was this element
originally in." A per-record version field would therefore carry no
information a per-file field doesn't already carry as of the most recent
save, and would add bookkeeping (updating N version fields instead of one)
for zero actual benefit given this codebase's actual write pattern.

**Option: sidecar file** (e.g. `proofs.schema-version` alongside
`proofs.json`), rejected as the primary mechanism.
- *For*: the main file's byte format is never touched by introducing
  versioning at all — the very first version-carrying change carries zero
  risk to the array-decode path that exists today.
- *Against*: introduces a new two-file atomicity problem this codebase does
  not have today. Every store currently writes with a single
  `data.write(to:fileURL, options: .atomic)` call
  (`ProofStore.swift:119`, and identically in the other two stores) —
  one atomic write, one file, no partial-write window. A sidecar
  necessarily adds a second file that must be kept consistent with the
  first; a crash between the two writes leaves either a version claim that
  doesn't match the actual bytes, or a missing sidecar next to an
  already-versioned main file (itself needing a "sidecar absent" bootstrap
  rule, same complexity as the envelope's "no envelope present" rule, but
  now duplicated across two failure surfaces instead of one).

**Option: envelope object (recommended).**
- *For*: stays inside the existing single-atomic-write shape (the
  version and the records are one JSON document, written by the same
  `data.write(to:, options: .atomic)` call that exists today — no new
  cross-file consistency problem). The bootstrap discriminator (does the
  top-level JSON token start with `{` or with `[`) is a structural,
  unambiguous check available *before* any field-level decoding happens —
  it does not share any of §5's corrupt-vs-old ambiguity, because "is the
  root token an object or an array" is answerable from the first character
  of well-formed JSON, independent of whatever fields either shape
  contains.
- *Against*: this is itself a breaking change to the top-level shape — code
  written *before* this decision ships would fail to decode an
  enveloped file with a `DecodingError.typeMismatch` at the root, the same
  failure category as everything else in this document. This is not
  avoidable in the abstract (any version-carrying change to a format that
  has never carried one needs *some* bootstrap step), but it means the very
  first PR implementing this decision must itself follow §5's
  recommendation (peek the root token before attempting the typed decode)
  rather than being a plain `JSONDecoder().decode(Envelope.self, ...)`
  call — the general mechanism and its own first use are the same change,
  which is worth stating plainly rather than treating as a detail.

## 4. Decision 2 — what happens when a lower/missing version is read?

**Recommendation: migrate-and-rewrite, applied eagerly at the end of
`load()` — a read-compatibility shim is the necessary mechanism underneath
this (you cannot migrate a shape you cannot first read), but the *policy*
of when to apply it should be eager, not lazy-on-next-write.**

This recommendation has a direct, already-shipped precedent in this exact
codebase, not a hypothetical: `ProofStore.load()`
(`ProofStore.swift:99-113`) already reads the full array, mutates any
element whose `signatureState` is `.connecting`/`.awaitingApproval` to
`.deferred` in memory, and calls `save()` immediately if anything changed
(`if didSanitize { save() }`, `:111-113`) — read, migrate in memory,
eagerly persist the migrated shape back, all inside `load()`, before the
constructor returns. This is precisely the shape decision 2 is asking for,
already built for a different reason (session-crash sanitization, not
schema versioning) one field over. `save()` itself already guards on
`isPersistenceSuspended` (`ProofStore.swift:117`,
`guard !isPersistenceSuspended else { return }`) — meaning the eager-rewrite
call sites do **not** need any new suspension-awareness of their own; the
existing precedent already composes correctly with `CorruptStoreQuarantine`'s
write-suspension outcome for free.

**Option: read-compatibility shim only, no eager rewrite (lazy — old shape
persists on disk until the next unrelated write).**
- *For*: strictly fewer disk writes; a session that only reads (opens the
  app, looks at old proofs, does nothing else) never touches disk.
- *Against*: a file can sit at an old version indefinitely if the user
  never triggers another `add`/`updateSignatureState`/`updatePeersVerified`
  call — meaning the shim code must be kept correct and exercised
  *forever*, for every version that has ever shipped, since there is no
  guarantee it ever gets to retire. This is a real, open-ended maintenance
  cost the eager option avoids by converging every touched file to the
  latest version quickly.

**Option: migrate-and-rewrite, eagerly on load (recommended).**
- *For*: matches an existing, shipped precedent in the same `load()`
  method 1:1; converges files to a single current version quickly, bounding
  how many historical shim paths must be kept correct simultaneously (a
  file that has been opened once since the last schema bump no longer needs
  any of the older shims exercised against it again); composes for free
  with the existing suspension guard, per above.
- *Against*: turns every `load()` of an old-versioned file into a write,
  even for a purely read-only session — a real behavior change (this
  codebase's stores today only write in response to explicit user actions
  that call `add`/`update*`; migration would add an implicit write
  triggered by app launch alone). Worth naming plainly since it is a new
  category of side effect for these stores, not because it is
  unprecedented in principle (the sanitize-then-save precedent already
  established the pattern) but because doing it *every app launch, for
  every store, for every schema bump* is a larger surface than the one
  narrow case that pattern was built for.

## 5. Decision 3 — distinguishing genuinely corrupt from old-but-valid (the core of the issue)

Today, both collapse to the identical signal: `JSONDecoder().decode(...)`
throwing any `DecodingError`, which `CorruptStoreQuarantine.resolve`'s
`guard loadFailure is DecodingError else { ... }`
(`CorruptStoreQuarantine.swift:65`) treats uniformly as corruption, with no
secondary check of any kind. gh#155 names this "ここが核心" and this
document agrees — every other decision point is downstream of getting this
one right.

**Recommendation: peek the version discriminator from §3's envelope
*before* attempting the full typed decode; dispatch on what that peek
finds; only a version-peek that itself cannot be parsed, or that names a
version this build has never heard of, falls through to
`CorruptStoreQuarantine`.**

Concretely (illustrative shape, not a design decision):

1. Attempt to decode only `{"schemaVersion": Int}` from the raw bytes (a
   minimal, permissive partial decode — e.g. `JSONSerialization`'s
   untyped object peek, or a `struct VersionPeek: Decodable { let
   schemaVersion: Int? }`). If this succeeds and yields a version this
   build recognizes (0 through current), proceed to typed decode using
   that version's known shape, then §4's migration path if it is not the
   current version.
2. If the peek succeeds but the root token is a bare array (no
   `schemaVersion` key at all — this is every file that predates this
   decision entirely), treat that as version 0 per §3's bootstrap rule and
   proceed identically to (1).
3. If the peek succeeds and finds a `schemaVersion` **higher** than
   anything the running build recognizes, this is not corruption — it is
   evidence of a downgrade (a user reverting an app update, or a TestFlight
   build rollback within the group). See the downgrade sub-finding below.
4. Only if the peek itself fails to parse as *any* recognized shape (not
   valid JSON at all; valid JSON but neither an object with a
   `schemaVersion` key nor a bare array) does the file fall through to
   `CorruptStoreQuarantine`'s existing mechanism unchanged.

**Option: try progressively older Codable shapes in sequence, with no
explicit version marker at all ("sniff by trying decode variants")** —
considered and rejected as the primary mechanism.
- *For*: works retroactively even without §3's bootstrap, since "no
  version marker, decodes under today's exact current shape minus any new
  fields" is itself one of the shapes tried.
- *Against*: requires keeping every historical `Codable` shape as live code
  indefinitely, tried in some order, with no principled stopping point
  other than "we ran out of known shapes" — the state space of "is this
  shape N-2, or shape N-1, or genuinely corrupt" is not bounded the way a
  single peeked integer is, and for a schema evolution that is purely
  additive (the common case — a new optional field, or a new enum case),
  a corrupted file could plausibly parse successfully under some *older*
  shape's laxer requirements by coincidence, misclassifying real corruption
  as "just old." An explicit version field makes "corrupt" a falsifiable
  predicate (fails to parse any recognized envelope) instead of an
  inference from which of several shapes happens to accept the bytes.

**Downgrade sub-finding (not one of gh#155's own four points, but directly
adjacent — the version-peek mechanism this decision recommends surfaces it
for free, so it needs an explicit answer rather than being silently
absorbed into either "old" or "corrupt"):** a `schemaVersion` the running
build has never heard of, because it is *higher* than the current build's
own version, is real, parseable evidence of exactly one thing — this file
was last written by a newer build than the one now reading it. Quarantining
it (treating it as corrupt) would destroy a perfectly valid, simply
not-yet-understood file the moment a rollback happens. Migrating it
(treating it as old) is not possible either — this build has no idea what
shape a future version actually is and cannot honestly claim to read it.
**Recommendation: suspend writes for that store instance without
quarantining**, reusing the exact `.unpreserved(Error)` outcome
`CorruptStoreQuarantine.Outcome` already defines for "a real file that must
not be touched" (`CorruptStoreQuarantine.swift:26-32`) — the same posture
the mechanism already takes for a data-protection-locked read. This
requires no new API surface, only a new caller of the existing
`.unpreserved` outcome from a site earlier than today's single
`DecodingError`-triggered call.

## 6. Decision 4 — how should an unknown `ProofSignatureState` case be handled?

Two genuinely different options, addressed separately because they answer
different questions: *should `signatureState` specifically degrade safely*,
versus *what is the general pattern for an enum that must preserve an
unrecognized value rather than discard it*.

**Option A — dedicated `.unknown` fallback case, with a hand-written
`Codable` conformance replacing today's synthesized one.**

On decode, if no known case name matches, capture the raw case name (and,
to make round-tripping possible, the raw associated-value JSON verbatim —
e.g. as `Data` or an opaque `[String: AnyCodable]`-shaped blob) into a new
`.unknown(caseName: String, rawPayload: Data?)` case.

- *For*: preserves information — the record survives with its actual,
  original (if unrecognized) signature state recorded, rather than
  discarded. If encoded back out verbatim (not re-synthesized into a new,
  meaningless shape), a value written by an intermediate build that didn't
  understand a case can still be correctly understood by a *later* build
  that re-adds support for it — this is the only option of the two that
  survives a "skip a version, come back later" scenario.
- *Against, real*: this is exactly the cost the task's own framing names.
  Every exhaustive `switch` over `ProofSignatureState`, present and future,
  needs a `.unknown` arm added and kept — this session located at least
  four such exhaustive switches by direct grep (not claimed exhaustive, but
  real, current sites): `ProofSignatureControlsView.swift:36`
  (`statusRow`), `:67` (`detail`), `:91` (`action`), and
  `ProofStore.swift:101` (the sanitize switch in `load()`). Beyond the
  one-time cost of adding the arm, this loses `Codable`'s free/verified
  synthesis permanently — every future case added to the enum requires
  hand-maintained decoder/encoder edits kept in sync with the case list, a
  standing cost `Codable` synthesis exists specifically to avoid. And, per
  the task's own framing: a lazily-written `default:`/`.unknown`-catching
  arm at any of those switch sites in the future risks silently absorbing a
  legitimately new, intentionally-different case's handling into the
  generic unknown-case fallback rather than giving it its own designed
  treatment — a code-review discipline risk this option introduces and the
  synthesized-Codable status quo does not have.

**Option B — narrow the failure to the one field, defaulting on decode
failure rather than only on absence (recommended for `ProofSignatureState`
specifically).**

Change `Proof.init(from:)`'s `signatureState` line
(`Proof.swift:75`) from catching only *absence* (today's
`decodeIfPresent`) to also catching a *decode failure of a present key's
value*, substituting the same `.notRequested` default in both cases —
narrowing the failure from "the whole array fails to decode" (§2.4) to
"this one proof's signature state resets to a safe default, everything else
about it, and every other proof in the file, is unaffected."

- *For*: minimal — a few lines, entirely local to `Proof.init(from:)`,
  using the same catch-and-default idiom this codebase already trusts
  elsewhere. No new persisted case, no new `Codable` shape, no exhaustive-
  switch tax anywhere else in the app. Directly consistent with this
  field's own documented design: `ProofSignature.swift:11`'s doc comment
  already states signing is "an optional enrichment layered on top, never a
  gate" — the codebase has already decided this specific field is
  expendable relative to the `Proof` it decorates, which is exactly the
  premise this option relies on.
- *Against, real*: discards the actual unrecognized value with no
  round-trip — unlike Option A, a later build that comes to understand the
  new case gets no benefit from what this build saw; the information is
  gone the moment `.notRequested` is substituted and (per §4) the file is
  eventually rewritten under the current shape. This is an accepted,
  named cost specific to `signatureState`'s status as decoration, not a
  general answer: it does not generalize to `BindingRecord`/
  `SelfProofRecord`'s own fields as they stand today, both of which
  (§2.5) have no custom decoder and no field the codebase has designed as
  expendable the way `signatureState` explicitly is.

**Recommendation: Option B for `ProofSignatureState` today** — it directly,
narrowly satisfies gh#155's third acceptance criterion
("`ProofSignatureState` に case を追加しても、旧ファイルが読めること") at
the field's own documented tolerance level, without paying Option A's
standing exhaustive-switch maintenance tax for a field this codebase has
already decided is expendable. **Reserve Option A as the general pattern**
for a future case where the *value itself*, not just the record it
decorates, must survive being written by a build that doesn't understand it
— which is not `signatureState`'s situation today, but could be a future
field's, and this document does not attempt to enumerate which one that
might be.

## 7. Migration-testing strategy

No real schema change exists yet to test a migration against (§10 confirms
this precisely). A future implementer proves the path works using fixtures
that do not depend on any change having actually shipped:

1. **A "version 0" fixture per store**, hand-authored or captured from
   `JSONEncoder().encode(...)` output of today's *actual, currently-shipped*
   `Proof`/`BindingRecord`/`SelfProofRecord` shape, checked in as a literal
   bare-array JSON file (e.g. `ios/BeidTests/Fixtures/proofs-v0.json`).
   Proves the §3 bootstrap rule ("no envelope present ⇒ version 0")
   recognizes and reads real, currently-shipping bytes — this fixture is
   authorable today, with zero product-code changes, because it is simply
   today's format frozen in a file.
2. **A genuine-corruption fixture** in the same test, alongside (1) — e.g.
   arbitrary non-JSON bytes, or valid JSON that matches neither a bare
   array nor a recognized envelope object. Necessary specifically because
   §5's mechanism could be *too* permissive as well as too strict; a test
   that only ever exercises "recognized old version" without also
   exercising "still correctly rejected as corrupt" would not catch a
   version-peek implementation that accidentally accepts everything.
3. **An unknown-enum-case fixture**, testable today with zero product code
   changes: a literal JSON blob containing
   `{"signatureState":{"expired":{}}}` for some fictional case name that
   does not and need not ever exist in the real enum — §2.2 confirmed any
   unrecognized case name (not just some specific future one) produces the
   identical `DecodingError.typeMismatch`, so this fixture validates §6's
   chosen mechanism immediately, without waiting for a real future case to
   be designed and shipped.
4. **A forward/downgrade fixture**: an envelope with a `schemaVersion`
   higher than any version the test build recognizes (e.g. `999`). Proves
   §5's downgrade sub-finding — write-suspension, not quarantine, not a
   crash.
5. **A frozen fixture per version that ever actually ships from here on.**
   Every future PR that changes one of these three schemas should add a
   new fixture file capturing the *exact* bytes its new version produces,
   and never delete or update a previously-frozen one. This is how the
   "prove the migration path works" requirement stays provable
   indefinitely rather than only at the moment a migration is first built:
   each frozen fixture is a permanent regression target for "can this
   version still be read," the same role `CorruptStoreQuarantineTests
   .swift`'s existing corrupt-bytes fixtures already play for the
   corruption path.

`CorruptStoreQuarantineTests.swift`'s existing structure (isolated temp
directory per test via `makeIsolatedDirectory(named:)`, write raw bytes
directly to the store's expected file path, construct the store, assert on
`records`/`quarantinedFileURL`/`isPersistenceSuspended`) is the direct
structural precedent for how all of the above should be authored — reuse
that harness rather than inventing a new one.

## 8. Acceptance criteria

Restating gh#155's own four checkboxes as testable conditions, plus two
additions from this document's own findings (marked **new**):

1. **Old-schema files are not quarantined (at least one generation back).**
   Test: given a §7(1)-style version-0 fixture for each store, assert
   `load()` produces the full expected record set and `quarantinedFileURL`
   is `nil`.
2. **"Old" and "corrupt" are distinguished, and old-only files are not
   quarantined.** Test: given both a §7(1) old-but-valid fixture and a
   §7(2) genuinely-corrupt fixture presented to the same store type in
   separate test runs, assert the old fixture never sets
   `quarantinedFileURL` while the corrupt fixture still does (i.e. §5's
   mechanism must not become so permissive that it stops catching real
   corruption — this is the same requirement stated from the opposite
   direction).
3. **An added `ProofSignatureState` case does not lose the file.** Test:
   given a §7(3) unknown-case fixture inside an otherwise-valid `Proof`
   array, assert `ProofStore.load()` still yields every proof in the file
   (not zero, not quarantined) — restates gh#155's third criterion using
   Decision 4's chosen mechanism (§6).
4. **The above is provable by test, using fixtures hand-authored to
   represent an old schema.** Satisfied by §7 collectively — restated here
   only because gh#155 lists it as its own, fourth, explicit checkbox
   rather than leaving it implicit in criteria 1–3.
5. **New (§5's downgrade finding): a `schemaVersion` newer than the running
   build recognizes suspends writes rather than being quarantined or
   crashing.** Test: §7(4)'s fixture, assert `isPersistenceSuspended` is
   `true` and `quarantinedFileURL` is `nil`.
6. **New: no regression to the current-version path.** Test: every
   existing test in `ProofStoreTests.swift`/`CorruptStoreQuarantineTests
   .swift` continues to pass unmodified — Decision 1's envelope bootstrap
   and Decision 3's version-peek must be a no-op for a file already at the
   current version (or, before any of this ships, for a bare-array file
   that this same code now treats as version 0).

## 9. Explicitly out of scope

- **Redesigning `CorruptStoreQuarantine`'s core mechanism.** It remains
  correct and needed for genuine corruption, unchanged. This document
  proposes a *prior* check — "is this recognizably an old-but-valid
  schema, or an unrecognized-but-parseable future one, before assuming
  corruption" — layered in front of the existing quarantine call, not a
  replacement for what happens once something really is corrupt.
- **Implementing any of §3–§6's recommendations.** No product code changes
  in this document, per the task's explicit instruction and SubPM's
  charter reservation of gh#155 for escalation.
- **`SelfProofCheckpointStore`** (`ios/Beid/Persistence/
  SelfProofCheckpointStore.swift`) uses the identical
  `CorruptStoreQuarantine` mechanism (`:69-76`) and would have the same
  latent gap in principle. It is not one of gh#155's or the task's named
  three stores, and its checkpoint is a transient, self-correcting
  single-record file rather than an accumulating history of user-visible
  proofs (`docs/specs/session-end-finalization.md` §7.1/§8.3) — the actual
  harm gh#155 describes (a whole visible history vanishing) does not apply
  to it the same way. Named here for completeness, not brought into scope.
- **`shared/` migration of these stores.** None of `Proof`/`BindingRecord`/
  `SelfProofRecord`/`ProofSignatureState` appear anywhere in
  `docs/kmp-shared-foundation.md`'s migration inventory (grepped directly,
  no hits) — they are not currently classified as a KMP-shared family at
  all, so this document's recommendations are scoped entirely to native
  iOS code, consistent with §11.

## 10. Urgency, per the issue's own framing — has anything already shipped that needs retroactive handling?

gh#155's own "期限の性質" section states plainly: **"スキーマを変更する前に
決着していれば足ります。ただし変更した後に気づくと、その時点で出荷済みの端
末では手遅れです（隔離済みファイルからの復旧は手作業になります）"** — i.e.
this is fully preventable if resolved before the next schema change ships,
and becomes a manual-recovery problem for real users the moment a breaking
change ships first.

Checked directly via `git log` on `origin/main` against the three model
files (`Proof.swift`, `ProofSignature.swift`, `BindingRecord.swift`,
`SelfProofRecord.swift`) for every commit after PR #157
(`61a5e75`, merged 2026-08-08 15:48:26 JST, the commit that introduced
`CorruptStoreQuarantine` and therefore the point after which any schema
change first becomes capable of triggering gh#155's failure mode): exactly
one commit touches any of the four files —
`149d5a6` (PR #174, closing gh#137, merged 2026-08-09 14:59:34 JST), which
touches only `Proof.swift`, adding the `eventCode: String?` field (visible
today at `Proof.swift:37`, decoded via `decodeIfPresent` at `Proof.swift:76`
— confirmed by direct read, not inferred from the commit message).

**This one already-shipped change does not trigger gh#155's failure mode.**
It is a strictly additive, `Optional`-typed field decoded with
`decodeIfPresent` — exactly the tolerance §2.3 verified empirically works
correctly for a missing key. No pre-existing `proofs.json` was or will be
quarantined by this specific change; there is nothing to manually recover
today. This was not incidental: `DECISIONS.md`'s own 2026-08-09 "#137 は履歴
スコープを採り" entry explicitly reasoned from gh#155's own text before
approving the addition ("#155 は... フィールドを足す方向には一定の耐性が
ある... 値(enum case)を足す方向には耐性が無いと明記しており... optional
フィールドの追加は #155 が警告する危険域に入らない") — i.e. the PM already
made one correct, narrow, ad hoc judgment call inside the specific tolerance
§2.3 confirms exists, while gh#155 itself remains open and general.

No commit since PR #157 touches `BindingRecord.swift`, `SelfProofRecord.swift`,
or adds a case to `ProofSignatureState`. **As of today (2026-08-09), this
document's recommendations remain fully preventive** — no already-shipped
change owes any retroactive migration or manual recovery. The next schema
change to any of the three stores that does *not* stay inside the narrow
"additive `Optional` field, `decodeIfPresent`" tolerance §2.3 verified —
in particular any change to `BindingRecord`/`SelfProofRecord` at all
(§2.5: neither has ever exercised this tolerance), or any new
`ProofSignatureState` case — would trigger gh#155's failure mode
immediately, with no migration path built yet.

## 11. Both-OS note

**iOS-only, and not by omission.** `ProofStore`/`BindingRecordStore`/
`SelfProofStore`/`ProofSignatureState` are all iOS-only types under
`ios/Beid/`. Per `AGENTS.md`'s current-state paragraph: "Android currently
has only the Event Join screen, and `EventJoinCoordinator` stops at `Idle`,
`RequestingPermission`, `Sensing`, or `PermissionDenied`. The entire
post-join screen flow — event found, recording (including the one-time
proof entrance), signal-loss recovery, and collection home — is absent on
Android today." Android has no equivalent store, no equivalent model, and
no code path that could exhibit gh#155's failure mode at all — there is
nothing to fix or touch there. This names the actual current gap (an
Android flow that does not exist yet) per `AGENTS.md`'s both-OS rule,
rather than leaving the platform silently untouched.
