# Spec — Collection & Item Detail: event-level display aggregation (beid#217)

Status: **DRAFT — spec only, cleared for review, not yet cleared for
implementation.** Written by Worker a-20260817-105 for SubPM a-20260817-099.
No code in this repository has been changed to produce this document.
Owner: SubPM a-20260817-099, for PM (beid).
Scope strategy: display-only aggregation. `Proof` stays session-granular;
only `CollectionHomeView`, `ProofCardView`, and `ItemDetailView` (plus,
optionally, `ParticipationSummaryView`) change how they present an existing,
unmodified `[Proof]`.

Ground truth, in precedence order:

1. `gh issue view 217 --comments`, the **2026-08-17 ruling comment**
   ("2026-08-17 裁定 — 表示側で集約する(選択肢 i)") — overrides the original
   issue body's "store-side dedup bug" framing. The fix is display-only;
   `Proof` grain stays per-session.
2. `/Users/ko/agent-workspace/projects/beid/DECISIONS.md`, 2026-08-17
   "Proof の粒度はセッション単位のまま、コレクションと詳細をイベント単位へ
   集約する(#217)" — the binding decision. Selects Decision i (explicit
   session list) over Decision ii (single representative + "latest session"
   label), with ii recorded as the pre-agreed fallback if i does not land by
   8/20.
3. `AGENTS.md` — Localization Process (§ below plans against it) and the
   both-OS feature rule (this slice is iOS-only presentation over an
   iOS-only screen flow; Android has no post-join screen flow at all today,
   per `AGENTS.md`'s current-state paragraph, so there is no Android call
   path to touch — that is the AGENTS.md-sanctioned reason, not silence).
4. Current source (`CollectionHomeView.swift`, `ProofCardView.swift`,
   `ItemDetailView.swift`, `ParticipationSummaryView.swift`,
   `TransparencyView.swift`, `AppCoordinator.swift`, `Proof.swift`,
   `ProofStore.swift`, `SensingCoordinator.swift`), read directly for this
   spec, not summarized from memory.
5. `docs/specs/collection-redesign.md` and `docs/specs/itemdetail-redesign.md`
   — approved visual specs for the two screens this slice extends.
   **`itemdetail-redesign.md` is stale**: it predates the Transparency
   (#137) and Participation summary (#143/#166) `BeidPanel` rows that exist
   in current `ItemDetailView.swift`. Where it conflicts with current
   source on those two rows, current source governs.

A separate, explicitly out-of-scope issue exists for `gradientSeed`
instability (`Proof.gradientSeed` defaults to `eventName.hashValue`, and
Swift's `String.hashValue` is not stable across process launches per
SE-0206 — DECISIONS 2026-08-17 "gradientSeed が `eventName.hashValue` 由来の
ためプロセス跨ぎで安定しない"). This spec does not assume `gradientSeed` is
stable per event across app runs; see §5.1 and §6.1.

## 1. Scope

**IN**:

- `CollectionHomeView.swift` — grid grouping by `eventCode`, one card per
  distinct event, updated count caption.
- `ProofCardView.swift` — optional session-count affordance for
  multi-session events.
- `ItemDetailView.swift` — resolve a group's sessions internally from the
  single representative `Proof` it already receives; top-panel "Devices
  sensed" resolution for multi-session groups; route to a session list
  instead of a single `ParticipationSummaryView` call when the group has
  more than one session.
- `ParticipationSummaryView.swift` — one small, additive, optional
  parameter (§6.3) so a session reached via the new list can show which
  session it is. Not required for the single-session path, which must
  render byte-for-byte as it does today (§6.4).
- Localization: new/changed strings across `en`/`ja`/`zh-Hans`/`es`/`fr`
  (§8).

**OUT** (see §9 for the full list; summarized here):

- Any `Proof`/`ProofStore` schema, field, or timing change. No dedup, no
  proof carry-forward across sessions, no change to when/how
  `SensingCoordinator.beginRecording` mints a `Proof`.
- `gradientSeed` determinism — separate issue, DECISIONS 2026-08-17.
- `AppCoordinator.swift`, `AccountSheetView.swift`, `EventCodeEntryView.swift`
  — PR #216 is open and unmerged and touches exactly these three files;
  §2 verifies this design does not need to touch them.
- #82's full Proof Detail IA / Token ID concept.
- Android — no post-join screen flow exists there today (AGENTS.md
  current-state paragraph); nothing in this slice has an Android call path
  to add.

## 2. Design finding — `AppCoordinator` stays untouched (verified)

`AppCoordinator.swift:14` declares `@Published var selectedProof: Proof?`
and `AppCoordinator.swift:138-140`:

```swift
func openProof(_ proof: Proof) {
  selectedProof = proof
}
```

`CollectionHomeView.swift:86-88` binds
`.navigationDestination(item: $coordinator.selectedProof) { proof in
ItemDetailView(proof: proof) }`. Both take a plain `Proof`, not a group or
event identity.

**This design keeps that contract exactly as-is.** `CollectionHomeView`
taps a card and calls `coordinator.openProof(representativeProof)` exactly
as today (§5.1 defines "representative"). `ItemDetailView` receives that one
`Proof` unchanged and derives the rest of its event's sessions internally:

```swift
private var groupSessions: [Proof] {
  guard let eventCode = proof.eventCode else { return [proof] }
  return coordinator.proofStore.proofs.filter { $0.eventCode == eventCode }
}
```

`coordinator.proofStore` is already a property `ItemDetailView` can read
(`AppCoordinator.swift:21`, `@EnvironmentObject private var coordinator:
AppCoordinator` already present in `ItemDetailView.swift:8`) — no new
dependency. Because `proofStore.proofs` is newest-first
(`ProofStore.add` inserts at index 0, `ProofStore.swift:40-43), `filter`
preserves that order, so `groupSessions` is already sorted newest-first with
no extra sort step.

**Conclusion: zero changes required to `AppCoordinator.swift`,
`AccountSheetView.swift`, or `EventCodeEntryView.swift`.** This holds for
every group shape (single-session, multi-session, `eventCode == nil`
singleton) because the derivation happens entirely inside `ItemDetailView`
from data it can already reach. This spec was designed to keep this
property; if a future implementer finds a reason it does not hold, that is
a blocker requiring escalation before touching any of those three files —
do not paper over it.

## 3. Grouping model (shared shape, used by both screens)

Both screens need "which proofs belong to the same displayed group," but
apply it differently (Collection needs every group's representative and
count; Item Detail needs only the current group's session list). Same key,
same rule, described once here:

- **Group key**: `proof.eventCode` when non-`nil`.
- **`eventCode == nil` proofs are never grouped with each other or with
  anything else.** Each such proof is a singleton group of exactly itself.
  This is a hard constraint from both the ruling comment and DECISIONS
  2026-08-17: nil predates #137 and carries no identity that would let two
  nil proofs be safely treated as "the same event."
- **Group order / representative**: because `proofStore.proofs` is already
  newest-first, the first proof encountered for a given key (scanning the
  array in its existing order) is both (a) the correct **representative**
  for that group's card (§5.1) and (b) determines the group's position in
  a newest-first grouped list, with no extra sort.

Reference algorithm (illustrative, not literal required Swift — the
grouping and its order fall naturally out of a single linear scan):

```
func eventGroups(from proofs: [Proof]) -> [[Proof]] {
  var order: [String] = []
  var groups: [String: [Proof]] = [:]
  for proof in proofs {                       // already newest-first
    let key = proof.eventCode ?? "singleton-\(proof.id.uuidString)"
    if groups[key] == nil { order.append(key); groups[key] = [] }
    groups[key]!.append(proof)
  }
  return order.map { groups[$0]! }
}
```

`CollectionHomeView` uses this to build one card per group (§5). Because
`ItemDetailView` only ever needs *one* group (the one containing the `Proof`
it was handed), it does not need the full grouping pass — the `filter` in
§2 is the group-scoped equivalent of the same key rule.

## 4. `gradientSeed` is not assumed stable per event

Per DECISIONS 2026-08-17, `Proof.gradientSeed` defaults to
`eventName.hashValue`, which is **not** stable across process launches
(SE-0206). Two sessions of the same event, recorded in different app runs,
can carry different `gradientSeed` values today. This spec's card
representative (§5.1) and detail artwork (§6.1) both render **the
representative proof's own `gradientSeed`**, with no assumption that it
matches any other session's in the same group, and no attempt to reconcile,
average, or pick a "canonical" seed across the group. Fixing seed stability
itself is the separate, already-filed issue; this spec must not regress or
paper over it by (for example) trying to make the group's cards look
falsely consistent.

## 5. Collection Home (`CollectionHomeView.swift`)

### 5.1 Grouping and card representative

**REVISED 2026-08-17, required PM fix — artwork is decoupled from
title/date.** The original draft of this section bundled artwork gradient,
title, and date onto one "representative" proof (the newest session). PM
review found a real design bug in that bundling, in the PM's own words:

> §5.1 makes the representative "the first proof in that group's session
> list, i.e. the newest session," and bundles artwork gradient, title, and
> date onto that one proof. §4 correctly refuses to assume `gradientSeed` is
> stable across sessions. Put those two together: user scans event A (card
> renders gradient X), scans it again days later in a new app run (new proof
> becomes the newest/representative, carries a DIFFERENT gradientSeed per
> #219) — the card in their collection changes appearance. Today's
> duplicate-card bug is wrong, but each card's artwork at least holds still.
> An item silently changing its identity is a worse failure than a
> duplicate — a duplicate is visibly a bug, a mutating card looks like data
> loss.

**Resolution: artwork and title/date now come from two different sessions
in the group, chosen for two different reasons:**

- **Artwork / `gradientSeed`** — sourced from the group's **oldest**
  session, i.e. `group.last` (the array stays newest-first per §3, so the
  oldest session is always the last element). Once a card exists, it is
  pinned to that first-ever session's seed and never changes appearance
  again, no matter how many times the user re-scans the same event
  afterward. This holds today, independent of whether #219
  (`gradientSeed` stability) ever lands, and independent of #219's
  migration story for *already-stored* proofs (explicitly undecided per
  DECISIONS 2026-08-17) — the oldest-session choice is stable by
  construction, not by assuming any particular seed value is reproducible.
- **Title / date** — unchanged from the original reasoning: the group's
  **newest** session, i.e. `group.first`, so a user who just re-scanned
  sees their latest date reflected, not a stale older one.

`ProofCardView` gains a second, independent, additive input for this:

```swift
struct ProofCardView: View {
  let proof: Proof                 // still drives title + date, unchanged
  var artworkSeed: Int? = nil      // NEW — overrides proof.gradientSeed for the artwork only
  var sessionCount: Int = 1        // §5.2, already spec'd below
  ...
  Circle().fill(DS.Artwork.proofCardGradient(seed: artworkSeed ?? proof.gradientSeed))
```

`artworkSeed` defaults to `nil`, in which case the gradient falls back to
`proof.gradientSeed` exactly as today — this is the same additive-optional
shape §5.2's `sessionCount: Int = 1` and §6.3.1's `sessionDate: Date? = nil`
already use elsewhere in this spec, and it means every existing call site
(every `#Preview`, and any future single-session caller that never learned
about grouping) keeps compiling and rendering unchanged. `CollectionHomeView`
is the only call site that passes a non-nil `artworkSeed`, and it passes
`group.last!.gradientSeed` (verified non-empty by construction — see §3's
grouping — so this is not a force-unwrap of untrusted data).

For a single-session group (including every `eventCode == nil` singleton),
`group.last === group.first`, so `artworkSeed == proof.gradientSeed` and the
card renders byte-for-byte as it does today — this is the same
"degenerates to today's behavior" property §6.1 below states for
`ItemDetailView`'s equivalent fix, and both must hold for the single-session
behavior-preservation bar in §6.4/§10.

The **representative** proof passed to `coordinator.openProof(_:)` when a
card is tapped is still `group.first` (the newest session) — this part of
the original design is unchanged; only what drives the *artwork* changed. It
remains the identity `ItemDetailView` receives and derives `groupSessions`
from (§2, §6.1).

An `eventCode == nil` proof is its own singleton group of one and renders
exactly like a single-session event card (§5.2 badge condition is `count >
1`, never true for a singleton) — **not visually distinguished** from a
real single-session event card. This is deliberate: a missing `eventCode`
is an internal data-provenance fact (the proof predates #137), not
something meaningful to the person who collected it, and there is nothing
actionable they could do about it. Surfacing a "legacy"/"no code" marker
would expose an implementation detail with no user-facing meaning and would
also collide with the dense, minimal card DESIGN.md and
`collection-redesign.md` §3.3/§5.3 already established (no extra rows/
badges beyond what carries real signal). If this judgment turns out wrong
in review, the fix is additive (a small badge), not a redesign.

### 5.2 Session-count affordance on the card

**Resolution: yes, `ProofCardView` gains a session-count affordance when a
group has more than one session.** Silently collapsing multiple sessions
into one card with no indication of the count would reintroduce exactly the
problem #217 exists to fix in the other direction: the whole point of the
ruling (Decision i over ii) is that collapsing must not lose count
fidelity — a user should still be able to tell "I scanned this 3 times,"
not just "I scanned this."

- `ProofCardView` gains a new parameter, `sessionCount: Int = 1` (default
  preserves every existing call site — previews, and any future
  single-session caller — with no change).
- When `sessionCount > 1`, render a small secondary caption below the date,
  `DS.Font.meta` / `DS.Color.textSecondary` (same role/weight as the date
  line already uses, one visual step down — no new font/color token).
- Copy: an explicit, pluralized key (interpolated value, per AGENTS.md's
  key-reuse rule):
  ```swift
  String(
    localized: "proofCard.sessionCount",
    defaultValue: "^[\(sessionCount) sessions](inflect: true)",
    comment: "Caption on a Collection Home card for an event recorded more than once (the user re-scanned the same event in a separate app session). Count of distinct recorded sessions for this event, not devices or peers."
  )
  ```
  Never rendered when `sessionCount == 1` (the common case, and every
  `eventCode == nil` singleton) — no empty caption, no "1 session" text.
- `ProofCardView`'s accessibility label (`proofCard.accessibilityLabel`)
  appends the same fact when present, so VoiceOver users get equivalent
  information: e.g. "Proof of ETHGlobal Tokyo, Aug 15, 2026, 3 sessions."
  This requires widening that string's existing comment (still the same
  key — the *string* changes, the key does not, because the key is already
  explicit and parameterized; AGENTS.md's reuse rule applies to explicit
  keys surviving wording changes).
  **Implementation note**: build the composed sentence by reusing the
  *same* localized `proofCard.sessionCount` text (already independently
  pluralized above) as an appended clause, rather than baking a
  "\(sessionCount) sessions" fragment directly into
  `proofCard.accessibilityLabel`'s own `defaultValue`. A single
  `String(localized:)` call site cannot cleanly host two different
  interpolation shapes (2-part vs. 3-part sentence) under one key without
  either producing an opaque pre-formatted English substring for
  translators to blindly re-embed, or fighting the String Catalog's
  one-format-per-key model. Composing two independently-translated,
  already-pluralized strings (`proofCard.accessibilityLabel`'s existing
  base sentence + `proofCard.sessionCount`'s existing text, joined by
  `", "`) keeps both pieces correctly localizable on their own and matches
  AGENTS.md's reuse rule in the direction it actually protects (reuse an
  existing meaning, don't fork it under a second key) — this is what "the
  key does not [change]" means in practice: `proofCard.accessibilityLabel`'s
  own `defaultValue` stays exactly as it is today; only the *runtime
  composed value* passed to `.accessibilityLabel()` differs when
  `sessionCount > 1`.

### 5.3 Count caption

**Resolution: rename the key, count distinct groups, and word it as "proof
collected from N events" rather than "N events collected."**

Current code (`CollectionHomeView.swift:129-135`):
```swift
String(
  localized: "collection.proofCount",
  defaultValue: "\(coordinator.proofStore.proofs.count) proofs collected",
  ...
)
```
counts raw `Proof` entries — which is exactly the #217 bug surfaced in the
caption too (open/close the scan screen twice, the caption inflates by one
even though nothing new was verified). The caption must count **distinct
groups per §3** (each real `eventCode` = 1, each `eventCode == nil` proof =
1), matching the number of cards actually rendered in the grid below it.

**REVISED 2026-08-17, copy question raised by the PM.** The PM's concern,
verbatim:

> DESIGN.md §15 owns English vocabulary for this project, and its
> established usage is that a person collects proofs. "N events collected"
> reads as collecting events, which is not what happens — you attend an
> event and collect a proof of it.

Checked against `DESIGN.md` §15 directly (not from memory) before
answering. §15's actual text: "A proof is **collected** or **sealed**,
never 'minted', 'dropped', or 'claimed'" — the verb "collect" is defined
there with **proof as its grammatical object**, stated that plainly, with
no comparable sentence anywhere in §15 that makes "event" the object of
"collect." §15's vocabulary line also lists "proof" and "event" as
separate terms ("proof", "encounter", "event", "sense/sensing", "collect",
"seal", "verify"), not interchangeable nouns for the same thing. "N events
collected" makes "events" the head noun receiving "collected," which is a
different claim than §15 licenses — the PM's concern holds up against the
document's actual text, not just as an assertion.

**Resolution:** keep "collected" attached to "proof" as a mass noun (no
plural needed — this caption is not claiming exactly one `Proof` record
per event, which would be false for a multi-session group), and let
"events" carry the count as scope rather than as the counted noun:

```swift
String(
  localized: "collection.eventCount",
  defaultValue: "Proof collected from ^[\(groupCount) events](inflect: true)",
  comment: "Caption above the Collection Home grid: count of distinct events the user has collected a proof for (grouped by eventCode; each proof recorded before eventCode existed counts as its own event). \"Proof\" here is the mass-noun collected fact, per DESIGN.md §15's vocabulary (a proof is collected — the object of \"collect\" is proof, never the event itself), and the number scopes how many events that applies across; it is not a raw count of recording sessions — a user who scanned the same event twice still counts as one event here, and this caption does not imply exactly one Proof record per event."
)
```

Given the grid now shows one card per *event* rather than one card per
*recording*, `collection.proofCount`'s old wording was already wrong on
both grounds this revision fixes (raw-session counting, and DESIGN.md §15
vocabulary once the count changed from a proof-count to an event-scope).
Because the *meaning* changes (proof count → distinct event count), not
just the wording, this spec renames the key rather than editing
`collection.proofCount`'s `defaultValue` in place — the old key's comment
would otherwise describe a counting rule the string no longer implements.
`collection-redesign.md` §6 already tolerates orphaned keys as a
non-blocking PR cleanup note ("String Catalogs tolerate unused keys"); the
same applies here to `collection.proofCount`, left unused rather than
force-migrated.

This is also the first correct implementation of the plural markup
`collection-redesign.md` §6 already specified but current code never
adopted (current code just interpolates a raw `Int`, no ICU plural
variant) — bringing it into compliance with AGENTS.md's Pluralization rule
is folded into this rename rather than deferred again. The `^[...]`
inflection block wraps only "events" (never "Proof," which stays a fixed
mass noun regardless of count).

`ja`/`zh-Hans` need only the `other` plural variant filled (no plural
forms in those languages); `en`/`es`/`fr` need `one`/`other`.

## 6. Item Detail (`ItemDetailView.swift`)

### 6.1 Representative and internal session derivation

Per §2, `ItemDetailView` keeps its existing `let proof: Proof` parameter
and derives `groupSessions: [Proof]` internally (§2's `filter`).

**REVISED 2026-08-17, required PM fix — `artworkHeader` inherits §5.1's
bug and must be fixed the same way.** The original draft of this section
said "No change to `artworkHeader` itself," reasoning that it renders the
representative `proof` unchanged. That is wrong: `artworkHeader`
(`ItemDetailView.swift:52-73`) renders `proof.gradientSeed`,
`proof.eventName`, and `proof.date` **all from the single `proof`
parameter** `ItemDetailView` was navigated in with — exactly the bundled
shape §5.1 just rejected, and driven by the same single proof whose seed
changes across re-scans per #219. Verified directly against current
`ItemDetailView.swift:52-73` before writing this fix, not assumed.

**Resolution, mirroring §5.1's split exactly:**

- **Artwork / `gradientSeed`** — sourced from `groupSessions.last`
  (oldest session), not `proof`.
- **Title / date** — stays sourced from `proof` (`proof.eventName`,
  `proof.date`), unchanged. This is not a coincidental reuse of `proof`
  for two different roles: `proof` is *always* the newest session in its
  group by construction, because it is exactly the representative
  `CollectionHomeView` passed to `openProof(_:)` per §5.1's unchanged
  newest-first-representative rule, and §2's `groupSessions` filter
  preserves the newest-first order of `proofStore.proofs`. So
  `proof === groupSessions.first` always holds here, and using `proof`
  directly for title/date is equivalent to using `groupSessions.first` —
  either is correct; this spec keeps `proof` since it requires no new
  computed property.

```swift
private var artworkHeader: some View {
  VStack(spacing: DS.Space.l) {
    Circle()
      .fill(DS.Artwork.proofCardGradient(seed: artworkSeed))   // was: proof.gradientSeed
      ...
    Text(proof.eventName)                                       // unchanged
    Text(Self.dateFormatter.string(from: proof.date))            // unchanged
  }
}

private var artworkSeed: Int {
  groupSessions.last?.gradientSeed ?? proof.gradientSeed
}
```

**Degenerate-case check (required by this fix, and by §6.4's "must not
regress" bar for the single-session path):** for a single-session group —
including every `eventCode == nil` singleton, since §2's `filter`
short-circuits those to `[proof]` — `groupSessions.last == groupSessions.first
== proof`. Therefore `artworkSeed == proof.gradientSeed`, identical to the
pre-fix code path. This must hold for every single-session group with no
exception, and is exactly the same degeneracy argument §5.1 makes for
`ProofCardView`'s `artworkSeed` parameter — both call sites collapse to
today's behavior for the common case, verified explicitly here rather than
assumed from "the diff looks additive."

### 6.2 Top panel resolution (Method / Devices sensed / Status)

The assignment's crux table names Transparency vs. Participation summary as
the pair with mismatched scope that must never sit unlabeled together. The
top `BeidPanel` (`ItemDetailView.swift:24-33`) has the identical shape
problem one row earlier and one panel higher, and the crux table's silence
on it does not mean it is fine as-is:

| Row | Source | Scope |
|---|---|---|
| Method | `proof.method` | nominally session-scoped, but in practice a constant string (`"Bluetooth Sensing"`) — see §6.2.1 |
| **Devices sensed** | `proof.peersVerified` | **session-scoped** — this specific recording's own peer count |
| Status | fixed `"Verified"` text | unconditional, not a number, not scoped to anything |

**Resolution:**

- **Method** — keep unconditional, sourced from the representative `proof`,
  no change. Unlike "Devices sensed," `proof.method` is not a count and in
  current usage is the same literal string for every session of a device
  (`Proof.init`'s default `method: String = "Bluetooth Sensing"`); there is
  no plausible reading where showing the representative session's value
  here creates a false event-vs-session signal, because there is nothing
  numeric or session-particular being implied. No resolution needed beyond
  stating this explicitly, as instructed.
- **Devices sensed — the row this spec must resolve.** Showing only the
  representative session's `proof.peersVerified` here carries the exact
  same false-signal risk the PM rejected for Participation summary (§6.3):
  a number that looks like it describes the whole event but is actually one
  session's count, sitting directly above a genuinely event-scoped number
  (Transparency's `recordedWindowCount(forEventCode:)`). **Resolution: omit
  this row entirely when `groupSessions.count > 1`.** No fabricated
  event-scoped substitute is available or safe: summing `peersVerified`
  across sessions would double-count any device sensed in more than one
  session, which is a fabricated aggregate, not a real one — the same kind
  of manufactured precision DECISIONS 2026-08-09 ("相互観測数は端末上では 0
  のまま正直に表示する(捏造も概算もしない)") already rejected in a sibling
  context. Each session's own count remains fully visible and correctly
  scoped in the session list (§6.3) instead. The top panel therefore renders
  two rows (Method, Status) instead of three when `groupSessions.count >
  1`, and three rows (unchanged) when it is 1. No placeholder text replaces
  the omitted row — `BeidPanel`'s `VStack` already accommodates a variable
  row count.
- **Status** — unchanged. Fixed, unconditional text with no session or
  event scope; nothing to resolve.

#### 6.2.1 Non-goal

This spec does not attempt to make `Method` itself event-aware (e.g. "did
every session use the same method") — out of scope; see §9.

### 6.3 Session list (replaces the single Participation-summary destination
for multi-session groups)

Today, `participationSummaryRow` (`ItemDetailView.swift:135-166`) is a
`NavigationLink` straight to one `ParticipationSummaryView(eventName:,
aggregate: sessionAggregateSnapshot(forProofId: proof.id))` call, keyed on
the single `proof` this view was handed. For a multi-session group this
must instead let the user reach every session's own aggregate, each
correctly scoped to its own `proofId` — never one aggregate presented as if
it covered the whole event (the exact false-signal shape the ruling
rejects).

**Resolution**: `ItemDetailView`'s existing "View participation summary"
row branches on `groupSessions.count`:

- `groupSessions.count == 1` (including every `eventCode == nil`
  singleton): **unchanged today's behavior** — pushes directly to
  `ParticipationSummaryView(eventName: proof.eventName, aggregate:
  coordinator.sensingCoordinator.sessionAggregateSnapshot(forProofId:
  proof.id))`, exactly as today. See §6.4 — this is the common case and
  must not regress.
- `groupSessions.count > 1`: pushes to a new list-shaped view (working name
  `SessionParticipationListView`; exact type/file name is an
  implementation-time choice, not fixed by this spec) that is a pure
  router into the *same*, unmodified `ParticipationSummaryView` per
  session — it does not reimplement any aggregate rendering itself.

  Proposed shape:
  ```swift
  struct SessionParticipationListView: View {
    let eventName: String
    // Resolved by the caller (ItemDetailView, which already has
    // `coordinator`) — this view stays a pure display component with no
    // coordinator dependency, matching ParticipationSummaryView's own
    // existing shape (eventName + aggregate in, no store/coordinator ref).
    let sessions: [(proof: Proof, aggregate: BeidSharedKit.aggregation.SessionAggregate?)]
  }
  ```
  `ItemDetailView` resolves the `(proof, aggregate)` pairs from
  `groupSessions` (already newest-first per §3) by calling
  `coordinator.sensingCoordinator.sessionAggregateSnapshot(forProofId:
  proof.id)` once per session — the same call `participationSummaryRow`
  already makes for the single-session case, just repeated per session
  instead of once.

  - **Header**: reuse the plain `Text(verbatim: eventName)` header pattern
    already used by `TransparencyView`/`ParticipationSummaryView`, plus a
    count line:
    ```swift
    String(
      localized: "participationSummary.sessionList.header",
      defaultValue: "^[\(sessions.count) sessions](inflect: true) recorded for this event",
      comment: "Header above the per-session list on the Participation summary screen for an event recorded more than once. Count of distinct recording sessions for this event, not devices."
    )
    ```
  - **Row content, one per session, newest-first (matches `groupSessions`'
    order — no reason to diverge from the array's existing, already-
    established newest-first convention used everywhere else in this
    feature)**:
    - Leading: the session's own date, `Text(verbatim:
      dateFormatter.string(from: session.proof.date))` — verbatim, no
      localization key needed (same pattern `ItemDetailView`/
      `ProofCardView` already use for dates).
    - Trailing: if `session.aggregate != nil`, the mutual-device count for
      *that* session:
      ```swift
      String(
        localized: "participationSummary.sessionList.row.mutualCount",
        defaultValue: "\(Int(aggregate.mutualDeviceCount)) confirmed",
        comment: "Trailing value on one row of the per-session list on the Participation summary screen: the mutually-confirmed device count for that one specific session, matching the scope of the headline metric shown on the single-session Participation summary screen. Not a duration, not an index, not the event-wide Transparency count."
      )
      ```
      If `session.aggregate == nil`, **reuse the existing
      `participationSummary.notYetAvailable` key verbatim, unchanged** —
      the meaning is identical to that key's existing scope (no
      session-aggregate snapshot was ever persisted for this specific
      proof), just now rendered per-row instead of full-screen. This is
      the "missing ≠ zero" invariant `ParticipationSummaryView`'s own doc
      comments establish, preserved at row granularity rather than
      invented anew. **Do not** create a second key with the same English
      text but a narrower/different comment — that would violate AGENTS.md's
      "about to write the same `Text(...)` in a second place → explicit key"
      rule in the wrong direction (splitting one meaning into two keys),
      not the direction the rule guards against, but conceptually the same
      failure to reuse.
    - Tapping a row pushes `ParticipationSummaryView(eventName: eventName,
      sessionDate: session.proof.date, aggregate: session.aggregate)` — see
      §6.3.1 for the one small `ParticipationSummaryView` change this
      implies.
  - **Nav title**: reuse `"Participation summary"` (no new key) — from the
    user's perspective this list *is* the participation summary for the
    event, just structured as a list when there is more than one session
    to show; the destination screen reached per-row is the same screen
    used for the single-session case (§6.3.1), so keeping one title for
    the concept avoids introducing a second name for the same thing.
  - The entry-point row's own label on `ItemDetailView` stays "View
    participation summary" unchanged regardless of session count — the
    destination adapts (single view vs. list) but the row's own copy does
    not need to describe that internal branch.

#### 6.3.1 The one `ParticipationSummaryView.swift` change

`ParticipationSummaryView` gains one new, optional, additive parameter:
```swift
let sessionDate: Date?   // defaults to nil at every existing call site
```
When non-`nil`, render it as a small secondary line under the existing
header (`Text(verbatim: dateFormatter.string(from: sessionDate))`,
`DS.Font.supporting` / `DS.Color.textSecondary` — no new localization key,
verbatim date, same pattern as everywhere else in this spec). This exists
so that tapping session row 1 vs. session row 2 of the same event does not
land on two visually identical screens with no way to tell which session
is being viewed. When `nil` (every existing call site, and the
single-session path in §6.4), the screen renders **exactly as it does
today** — this parameter is additive only, never a behavior change to the
existing single-session call.

### 6.4 Single-session UX (the common case) — must not regress

A user whose event has exactly one recorded session (whether or not it has
an `eventCode`) must reach `ParticipationSummaryView` exactly as they do
today: one tap on "View participation summary," no intermediate list, no
"list of one." §6.3's branch on `groupSessions.count == 1` guarantees this
at the call-site level; §6.3.1's `sessionDate: Date? = nil` default
guarantees the destination screen itself is pixel-identical to today's
output for this path. This is the majority case today (every event with
exactly one recording) and must be verifiable as a no-behavior-change diff
at review time (§10).

### 6.5 `eventCode == nil` handling (restated for both screens)

- **Collection (§5.1)**: never merged with another nil proof or with any
  real-`eventCode` group; always its own singleton group; card renders
  identically to a real single-session event card, no visual marker (§5.1's
  reasoning).
- **Detail (§6.1–6.4)**: `groupSessions` for a nil-`eventCode` proof is
  `[proof]` — a singleton, by construction (§2's `filter` short-circuits to
  `[proof]` when `proof.eventCode == nil`, never scanning for other nil
  proofs). It therefore always takes the single-session path (§6.4):
  unchanged direct push to `ParticipationSummaryView`, never routed through
  the session list. This falls out of §6.1's derivation automatically —
  no separate nil-specific branch is needed in `ItemDetailView` beyond the
  `groupSessions` computation itself already handling it.

## 7. New/changed design-system tokens

**None required.** Every new piece of UI in this spec reuses existing
`DS.*` roles already in the two screens it extends:

- Session-count card caption (§5.2): `DS.Font.meta` / `DS.Color.textSecondary`
  — same role already used for `ProofCardView`'s date line.
- Session-list rows (§6.3): `BeidPanel`/row patterns already established by
  `TransparencyView`'s `TierRow` and `ParticipationSummaryView`'s
  `BeidMetricRow` usage — no new container or row primitive introduced by
  this spec; the implementer may reuse `BeidMetricRow` directly per row
  if its label/value shape fits, or a bespoke `HStack` matching
  `TierRow`'s pattern if a `NavigationLink` chevron is needed per row
  (mirroring `ItemDetailView`'s own `transparencyRow`/
  `participationSummaryRow` `HStack` + chevron pattern) — an
  implementation-time choice, not a spec-level token decision.
- `ParticipationSummaryView`'s new `sessionDate` line (§6.3.1):
  `DS.Font.supporting` / `DS.Color.textSecondary` — same role as its own
  existing header treatment for secondary text.

## 8. Localization plan (per AGENTS.md)

All entries below: authored in English first in code, machine-drafted
`needs_review` for `ja`/`zh-Hans`/`es`/`fr` in the same PR, following
`collection-redesign.md`/`itemdetail-redesign.md`'s own precedent.

| Key | Form | Notes |
|---|---|---|
| `collection.eventCount` | explicit, plural (interpolated + reused-shape) | New key, replaces `collection.proofCount` in call sites; old key left orphaned, not force-migrated (§5.3). Wording is "Proof collected from N events" (mass-noun "proof," count on "events"), not "N events collected" — required per DESIGN.md §15's collect-takes-proof-as-object vocabulary (§5.3). `en`/`es`/`fr` need `one`/`other`; `ja`/`zh-Hans` need only `other`. |
| `proofCard.sessionCount` | explicit, plural (interpolated) | New key. §5.2. Practically only ever renders the `other` form (guarded by `count > 1`), but author both forms per catalog convention. |
| `proofCard.accessibilityLabel` | explicit (existing key, changed `defaultValue`) | Wording widened to append session count when present (§5.2) — same key, no rename, since it is already an explicit, parameterized key per AGENTS.md's reuse rule. |
| `participationSummary.sessionList.header` | explicit, plural (interpolated) | New key. §6.3. |
| `participationSummary.sessionList.row.mutualCount` | explicit (interpolated) | New key. §6.3. Deliberately distinct from `headlineLabelKey`'s "Devices mutually confirmed" (a `LocalizedStringKey`, not this file's `String(localized:)` convention) — the list row is a compact trailing value, not a labeled metric row. |
| `participationSummary.notYetAvailable` | existing key, **reused verbatim, no change** | §6.3 — same meaning (no snapshot persisted for this proof), now also read per-row in the new list, not full-screen only. Must not be duplicated under a new key. |
| Session-list row dates, `ParticipationSummaryView`'s new `sessionDate` line | verbatim `Text`, no key | Dates are rendered verbatim via `DateFormatter` throughout this codebase (`ItemDetailView`, `ProofCardView` both do this today) — consistent with existing precedent, not a new pattern. |
| `detail.devicesSensed.label` | existing key, **unchanged** | §6.2 — the row using this key is conditionally *hidden* for multi-session groups, not reworded or duplicated. No orphaning: it stays fully used by the single-session (and singleton) path. |

**Known implementation-time trap (per AGENTS.md), noted here so it is not
rediscovered at implementation)**: `xcodebuild` from the CLI does **not**
sync new/changed keys into `Localizable.xcstrings` — that sync only runs
inside Xcode.app. The implementer must either build once in Xcode.app to
let the new keys land in the catalog, or hand-edit
`ios/Beid/Localizable.xcstrings` (plain JSON) to add the keys above with
`needs_review` state for the four non-English locales, then rebuild to
confirm no regression. A green CLI build is not evidence the catalog is in
sync.

## 9. Explicit out-of-scope list

- Any `Proof`/`ProofStore` schema, field, or default change. `Proof.swift`
  and `ProofStore.swift` diffs must both be empty.
- Any dedup, proof-carry-forward, or change to when/how
  `SensingCoordinator.beginRecording` mints a new `Proof` — the ruling
  comment and DECISIONS 2026-08-17 explicitly reject this direction; #217
  is fixed on the display side only.
- `gradientSeed` determinism — separate, already-filed issue (DECISIONS
  2026-08-17). This spec only states the non-assumption (§4), does not fix
  it.
- `AppCoordinator.swift`, `AccountSheetView.swift`, `EventCodeEntryView.swift`
  — verified untouched by this design (§2). If an implementer later finds
  this design does not actually avoid them, **stop and escalate before
  touching any of the three** — do not silently proceed.
- #82's full Proof Detail IA / Token ID concept — the session list in §6.3
  needs neither census expansion nor a Token ID concept; it is a plain list
  of existing `Proof`/`SessionAggregate` data already computable today.
- Any change to `Method`'s per-session semantics (§6.2.1) — it stays a
  representative-sourced, effectively-constant string.
- Android — no call path exists to add to (AGENTS.md current-state
  paragraph); not a silent omission.
- Any new DS token (§7 — none needed).
- Visual/pixel-level redesign of `CollectionHomeView`/`ProofCardView`/
  `ItemDetailView` beyond what's specified above — this spec is additive to
  the already-approved `collection-redesign.md`/`itemdetail-redesign.md`
  layouts, not a re-skin.

## 10. Acceptance criteria

- clean build = BUILD SUCCEEDED; `scripts/lint.sh` = 0 violations.
- `Proof.swift` and `ProofStore.swift` diffs are both **empty**.
- `AppCoordinator.swift`, `AccountSheetView.swift`, `EventCodeEntryView.swift`
  diffs are all **empty** (§2's verified design finding).
- **Behavior-preservation for the single-session path (§6.4)**: a `Proof`
  whose group has exactly one session renders `ItemDetailView` and
  (on tapping through) `ParticipationSummaryView` identically to today —
  same rows, same values, same nav titles, no list, no session-count
  caption on its `ProofCardView`. This must be checked as an explicit
  before/after comparison, not assumed from the diff being "additive."
- Collection grid shows exactly one card per distinct `eventCode` plus one
  card per `eventCode == nil` proof (§3, §5.1); count caption
  (`collection.eventCount`) matches the number of cards rendered.
- A group with N > 1 sessions: card shows the `N sessions` caption (§5.2);
  `ItemDetailView`'s top panel omits "Devices sensed" (§6.2) and its
  "View participation summary" row routes to the session list (§6.3), not
  a single `ParticipationSummaryView` call.
- **Artwork stability (§5.1/§6.1, PM-required fix)**: a group's card
  gradient and `ItemDetailView`'s `artworkHeader` gradient are both sourced
  from the group's oldest session (`groupSessions.last` /
  `group.last!.gradientSeed`) and therefore do not change in appearance
  across re-scans, regardless of how many new sessions are added to the
  group or what `gradientSeed` those new sessions carry. Title/date on both
  surfaces still reflect the newest session. Verify this explicitly by
  re-scanning the same `DemoEvent` event ≥2 times and confirming the card's
  and detail screen's artwork gradient is visually identical before and
  after the second scan, while the date line advances.
- Session list rows are newest-first, matching `groupSessions`'/
  `proofStore.proofs`' existing order; a row for a session with no
  persisted aggregate reads `participationSummary.notYetAvailable`
  (reused key, §6.3) — never a fabricated `0`.
- No two `eventCode == nil` proofs are ever grouped together, in either
  screen, under any test data shape.
- New/changed strings localized per §8, all four non-English locales at
  `needs_review` (machine-drafted acceptable), catalog hand-edited if the
  build ran via CLI only (per the trap noted in §8).
- `#Preview` variants added/updated for: `CollectionHomeView` (a populated
  variant with a multi-session group present, in addition to existing
  variants), `ProofCardView` (a `sessionCount > 1` variant), `ItemDetailView`
  (a multi-session variant), and the new session-list view (populated +
  a row with `aggregate == nil`), each light + dark per existing convention.
- UI tests updated for any assertion reading the old `"{n} proofs
  collected"` caption text or assuming one card per `Proof`.
- PR-sized; no `.xcodeproj` hand-edits; PR description states explicitly
  that `Proof.swift`/`ProofStore.swift`/`AppCoordinator.swift`/
  `AccountSheetView.swift`/`EventCodeEntryView.swift` are all untouched,
  and confirms the single-session-path behavior-preservation check above
  was performed.

## 11. 8/20 feasibility

**Plain read: achievable by 8/20, moderate-not-high confidence, main risk
is calendar/process latency rather than design or implementation
complexity.**

Reasons this is smaller than it might look:

- No `shared/`/KMP work at all — every data source this spec uses
  (`SensingCoordinator.recordedWindowCount(forEventCode:)`,
  `.sessionAggregateSnapshot(forProofId:)`, `ProofStore.proofs`) already
  exists and is already called from `ItemDetailView` today; this spec only
  changes how their results are grouped/displayed, not what's computed.
- No schema change, no new persistence, no new coordinator method.
- §2's design finding holds: zero collision surface with PR #216 (which
  touches `AppCoordinator.swift`/`AccountSheetView.swift`/
  `EventCodeEntryView.swift` — none of which this spec touches), so this
  work can proceed and merge independently of that PR's timeline.
- The touched-file set is small and bounded: `CollectionHomeView.swift`,
  `ProofCardView.swift`, `ItemDetailView.swift`, one new view file, and one
  small additive change to `ParticipationSummaryView.swift`.

Real risk, stated plainly rather than hedged:

- **The independent review gate (AGENTS.md "Review gate") is
  maintainer-dispatched, not author-schedulable** — its latency is outside
  the implementer's control and is the single biggest threat to the 8/20
  date, not implementation time itself. The PR should be opened as early
  as possible (recommend end of 2026-08-18) specifically to leave buffer
  for that dispatch-and-review latency, not to leave buffer for more
  coding.
- Manually producing multi-session test data (repeatedly opening/closing
  the scan screen against the same event to generate ≥2 `Proof`s sharing an
  `eventCode`, per the original issue's own repro steps) is straightforward
  but must actually be done by hand on a real/simulated device before
  merge — it is easy to under-test this feature by only ever exercising the
  single-session path, since that remains the majority case in the
  simulator's existing `DemoEvent` flow.
- Localization touches 4 locales × 5 new/changed keys (§8); mechanically
  small but each catalog hand-edit (§8's CLI trap) is a manual step that
  has bitten this repo before per AGENTS.md.

If implementation has not reached PR-open by end of 2026-08-18, recommend
falling back to the pre-agreed Decision ii (one representative card +
summary explicitly labeled "latest session") rather than risking a rushed
Decision i landing without adequate multi-session manual testing or review
turnaround. This spec does not make that call — it is flagged here per the
assignment's instruction to state the risk plainly, not silently substitute
the fallback.

## 12. Branch/PR note

Base on `issue-217-event-aggregation` (current branch, based on
`origin/main` at `870baec`) or rebase onto a fresher `origin/main` at
implementation time — independent of PR #216's branch, per §2's verified
no-collision finding. PR description must state the §10 diff-emptiness
claims explicitly (`Proof.swift`, `ProofStore.swift`,
`AppCoordinator.swift`, `AccountSheetView.swift`, `EventCodeEntryView.swift`
all untouched) so a reviewer can check them without re-deriving this
spec's §2 reasoning from scratch.
