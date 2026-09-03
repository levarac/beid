# iOS-alone critical path — 2026-08-09

Produced by SubPM a-20260808-026 for PM a-20260808-020, following the
2026-08-09 rulings that overwrote three prior decisions (see DECISIONS.md
entries dated 2026-08-09: *"#138 会場端末モードの運営者 UI を作る"*, *"census
拡張(Contributor Proof)を今期スコープへ戻す"*, *"8/20 の到達点は「iOS 単体で
一通り動く」"*). Recommendations only — this document rules on nothing.

**A note on freshness, load-bearing for everything below:** this SubPM's
local checkout of `main` was 7 commits behind `origin/main` when this task
started. Those 7 commits (`#146`, `#151`, `#153`, `#157`, `#159`, `#160`,
`#161`, landed 2026-08-08) closed 4 of the issues this document would
otherwise have treated as open (`#109`, `#128`, `#135`, plus `#154` which
was filed and closed same-day) and opened 3 new ones (`#155`, `#156`,
`#158`). This plan is built off `origin/main` as of this session, verified
via `git fetch` + `git show --stat` against the actual landed diffs, not
off issue text alone — issue text lags what's actually shipped in a couple
of places this document calls out explicitly.

---

## 1. Definition of done for "iOS alone works end to end"

**A single user, using only their own iPhone, alongside at least one other
iPhone (mutual BLE observation is inherently 2+ devices — "iOS alone" per
the 2026-08-09 ruling means *no Android device is required*, not that one
phone works in isolation; DECISIONS 2026-08-01 already established
real-device verification needs multiple iPhones in one place), must be able
to:**

| # | Capability | Grounded in | Status |
|---|---|---|---|
| 1 | Launch the app, grant Bluetooth permission, reach a sensing-ready state | DECISIONS 2026-07-26 (event-first onboarding flow) | **Shipped.** No open blocking issue beyond stale text in #53 (already flagged in the prior consolidation, not re-litigated here). |
| 2 | Join a **real, specific event** — not the shared "beid-demo-event" fallback every shipped build currently produces | DECISIONS 2026-07-26 ("イベント検知(またはイベントコード入力)でイベント確定"); #101 (the fallback bug); #100 (design); #141 (the UX-canonical redesign); #138 (2026-08-09 override, now required for the sender side) | **Not done.** This is the largest remaining item — see §2/§4. |
| 3 | Have their device sense peers, accumulate mutual observations across ENIN windows, and sign+persist per-window reports without silently losing data | DECISIONS 2026-07-26 (report granularity); #91 (session-end gaps); #155/#156 (new correctness bugs, found 2026-08-08) | **Mostly shipped**, with 2 correctness gaps still open — see §2. |
| 4 | Complete wallet binding (1 round trip) and have a self-proof exist that ties their per-event signing key to their wallet | DECISIONS 2026-08-03 (Barnard binding conformance, landed via PR #90/#92/#94); DECISIONS 2026-08-06 (gh#91 spec) | **Mostly shipped**, with #156 (owner-key seed can silently regenerate mid-use, orphaning existing self-proofs/bindings) as an open correctness gap. |
| 5 | See their recorded Proof in Collection/ItemDetail, with copy that doesn't overclaim what was actually measured | Existing shipped redesign slices (#67–#75); DESIGN.md §15 (no-overclaiming copy voice); #158 (found 2026-08-08 — "Peers verified" label no longer matches what the number means after #154's fix) | **Mostly shipped**, #158 is a small open label-correctness item. |

**Explicitly *not* required for "done," and why:**

- **Send path, verifier, #144's 6-stage contract** — DECISIONS 2026-08-09
  ("8/20 の到達点は「iOS 単体で一通り動く」") moves these past 8/20 by name.
- **Android parity (#117 and children)** — same ruling, by name.
- **#145 (public-data privacy schema)** — moot for 8/20 specifically
  *because* of the send-path deferral above: #145 constrains what gets
  published in the blob the report server would emit; with no send path,
  nothing is published, so there is no artifact yet for #145 to constrain.
- **#104 (Figma-vs-canonical visual-drift inventory)** — cosmetic parity,
  not functional completeness. Not part of this DoD; see §5's cut list for
  why it should stay explicitly deferred despite the 2026-08-08 decision
  that had queued it as the next thing after issue consolidation.
- **#114 (real N-device consensus threshold)** — the app already "works"
  with the current first-detection trigger; DECISIONS 2026-08-01 and
  2026-08-03 already accepted this exact behavior as the basis for real-device
  verification. See §3 for the full reasoning.
- **#131, #133, #134, #136 (ledger observability/durability edge cases)** —
  each issue's own text states current risk as negligible at this app's
  actual usage scale (see §5).
- **#132 (ledger-open failure silently drops a report forever)** — its own
  text states the failure path is unreachable today because *nothing calls
  `prepareNextUnsentWindowSubmission` yet* — that caller is the send path,
  which is deferred. This bug becomes live risk only when send-path work
  resumes; it is not part of the 8/20 critical path.

**What the user explicitly cannot do at 8/20**, stated per the assignment's
instruction: per DECISIONS 2026-08-09 itself, *"8/20 時点では「他人が検証で
きる出席証明」には到達しない(#144 の6段のうち検証者側が欠ける)"* — no
third party, including a future verifier, can confirm any user's
attendance. The Proof exists only on-device (plus best-effort iCloud sync,
DECISIONS 2026-07-26 data-ownership decision) with no external validation
path. This limit should be stated plainly whenever the 8/20 build is
described externally.

---

## 2. Critical path

Ordered by dependency, not by calendar day (day estimates are in §5). Three
tracks can run substantially in parallel (different code areas); within a
track, order matters.

### Track A — pipeline correctness (parallel to B and C)

| Issue | What | Hard dependency | Soft/degrades note |
|---|---|---|---|
| **#155** | Define schema-versioning discipline for Proof/BindingRecord/SelfProofRecord (distinguish "old" from "corrupt"; tolerate unknown `ProofSignatureState` cases) | none — do first | **Hard, and a gate**: its own text states *"スキーマを変更する前に決着していれば足ります。ただし変更した後に気づくと、その時点で出荷済みの端末では手遅れです"* (TestFlight users already have real accumulating data). Nothing else on this critical path is confirmed schema-safe until this lands — see §3/§4 for which items are most at risk. |
| **#156** | Stop the owner-key seed from silently regenerating mid-use and orphaning existing self-proofs/bindings | soft-sequenced after #155 (discipline, not a proven technical dependency — #156 touches `UserDefaults` key storage, not the file-based stores #155 covers) | Hard — a silent identity swap invisibly breaks the core attendance-proof chain (item 4 of the DoD). |
| **#91** (remaining scope only) | Gap 2 only: self-proof lost on force-quit after binding, via the already-approved checkpoint+recovery mechanism (`docs/specs/session-end-finalization.md`, sub-slice 3) | none | Hard — realistic to hit in any short/interrupted real-world session, which a demo or dogfood day both are. **Note: Gap 1 (last window not persisted) and the backgrounding case are already fixed** — DECISIONS 2026-08-06 confirms sub-slices 1 (PR #99) and 2 (PR #103) landed; only sub-slice 3 remains open under #91. |
| **#158** | Rename "Peers verified" to match what #154's fix actually measures (detected-device count, not verified mutuality) | none | Hard-but-cheap; needs a DESIGN.md §14 label decision + string-catalog/i18n pass (5 locales, per AGENTS.md). |
| **#131** | Replace `print()`-only ledger failure paths with `os_log` + internal health state | none | **Soft, strongly recommended.** Both correctness bugs found in this exact area (#146/#157's predecessors) were invisible until an independent review went looking — the same blind spot could recur. Cut candidate if time is short (§5), not a free cut. |
| #132, #133, #134, #136 | Ledger durability/observability edge cases | — | **Soft/defer** — see DoD table above for the specific reasoning per issue. |

### Track B — real participation surface (parallel to A and C; the largest item)

| Issue | What | Hard dependency | Status |
|---|---|---|---|
| `docs/specs/event-discovery.md` §9 revision | Rewrite §9.a/§9.b to reflect the 2026-08-09 override | none | Not started. DECISIONS 2026-08-09 names this explicitly: *"承認済み docs/specs/event-discovery.md §9.a/§9.b が本決定で陳腐化するため、spec の改訂が必要"*. This repo's own practice (gh#88, gh#91, gh#100) is spec-before-code — treat this as blocking #138's implementation, not optional. |
| **#138** | Venue-device organizer UI: start/stop broadcasting, required label + validity period, reassignment history | hard-depends on the spec revision above, on a TLV-transport design decision for label/validity (§4), and on Barnard-repo-side protocol support (`levarac/barnard#122`/`#123`, external, unverifiable from this repo) | Not started; just unblocked by the 2026-08-09 ruling. |
| #100 (native receiving-side wiring) | `SensingCoordinator` handling of `.eventInfoHint`, "nearby detected" UI in the join flow | none (shared-side logic already landed, PR #161) | **Partially shipped**: `EventInfoStore`/`EventWindowFilter`/`RelayMajority` pure functions landed in `shared/` (PR #161, 2026-08-08) — **zero iOS files touched by that PR** (confirmed via `git show --stat`). Native adapter wiring is unstarted and untracked by any issue narrower than #100 itself. |
| #139 (remaining native scope) | UI wiring for layers 1–2 (time-window filter, majority display — logic already shared per #161) + layer 3 (post-join self-correction, presentation-only, no shared dependency) | soft-depends on #100's adapter wiring landing first (shares the same `.eventInfoHint` plumbing) | Shared logic for layers 1–2 shipped 2026-08-08; native UI for all 3 layers unstarted. |
| **#141** | Event-card UI: zero-tap auto-start, rare-selection UI, retire EventCode entry as the primary path | **hard-depends on #100 + #139's native wiring** (needs their output to render); **hard-depends on #138** for the *real* (non-DEBUG) flow to have anything to display — see §4 | Not started. #101 (the specific unreachable-route bug) is resolved as a byproduct once #141 ships, per the prior consolidation's finding — not tracked as a separate critical-path step here. |

### Track C — visibility (parallel to A and B)

| Issue | What | Hard dependency | Status |
|---|---|---|---|
| (untracked) | Wire the already-shipped `shared` aggregation pure functions (`ObservationAggregation.kt`, PR #159) into an iOS adapter | none | **Gap found in this session**: PR #159's own commit message states *"scope: shared のみ。iOS adapter と Android production caller はこの commit に含まない"*. #109 (the issue this shipped under) is **closed** — the remaining native-wiring work has no open issue tracking it. Flagging this so it doesn't fall through a crack. |
| **#142** | Live mutual-observation tally on the recording screen | hard-depends on the adapter above | Not started — see §3 for the native-now-vs-wait analysis. |
| **#143** | Daily participation summary card | hard-depends on the same adapter (shares the wiring work with #142 — sequence together) | Not started — see §3. |
| **#137** | Transparency view, reduced to its 2 buildable-for-8/20 states (participation action; recorded locally) | **none** — reads the already-fully-wired unsent-window ledger (PR #146, iOS adapter exists) | Not started, but its hard dependency already shipped — cheapest of the three. The 3rd state ("verified"/receipt-based) is out of scope until send-path/verifier work resumes, per its own text degrading gracefully to this. |

---

## 3. The shared-dependency tension, per affected issue

For each: native-now vs. wait-for-`shared`, the concrete rework cost of
native-now (checked against KMP-002's boundary rule and the working
manual's Step 5 production-caller requirement, `docs/kmp-shared-foundation.md`),
and one recommendation.

### #142 — live tally

- **Shared status**: the pure functions exist (`ObservationAggregation.kt`,
  PR #159, 16 vectors covering per-window/per-band/per-session tri-level
  counts, mutual-vs-all-observation scope). No iOS adapter yet.
- **Native-now**: reimplement the same tally in Swift inside
  `SensingCoordinator`/`RecordingView`, bypassing `shared`.
- **Concrete rework cost**: directly violates the working manual's Step 5
  ("production caller を全数確認") and PR checklist item *"相互確認数、
  window/time-band 集計...は shared output であり、native は表示だけを行う"*.
  Worse, it risks reintroducing a bug shaped exactly like #154 (the
  double-counting defect just fixed by moving to display-id-stable
  counting) — a second, independently-written counting implementation is
  exactly the kind of divergence #154 came from. 100% of the native
  counting code becomes throwaway once the adapter lands; the display
  layer would also need re-testing against the new source of truth.
- **Recommendation: wait for the adapter.** The hard part (pure functions +
  vectors) already shipped; what remains is thin Step-3/4-style wiring,
  which the manual explicitly sizes as small by design.

### #143 — daily summary card

- Same shared dependency as #142 (same `ObservationAggregation.kt` family,
  session/day-level rollup instead of window-level), plus a
  presentation-only "card" composition layer.
- **Native-now**: same violation risk as #142.
- **Recommendation: wait for the same adapter #142 needs.** Sequence #142
  and #143 together — one adapter-wiring PR, two presentations — cheaper
  than treating them as independent.

### #137 — transparency view

- **Shared status**: its 2 buildable-for-8/20 states (action taken;
  recorded locally) read directly from the unsent-window ledger, which is
  **already fully converged and natively wired** (PR #146 — the diff
  touches `SensingCoordinator.swift`, `UnsentWindowLedgerStore.swift`,
  `UnsentWindowLedgerRuntime.swift`, `WindowReportStore.swift`, all on the
  iOS side, alongside the shared reducer). Its 3rd state ("verified") has
  no data source at all right now — not a KMP boundary question, a
  send-path/verifier existence question, and that's deferred regardless of
  where the code would live.
- **Native-now vs. wait**: no real tension for the 8/20-scoped version —
  there's nothing to "wait" for; the dependency already shipped.
- **Recommendation: build the reduced 2-state version now.** Zero new
  shared work required, explicitly defer the 3rd state's UI slot to
  whenever send-path/verifier work resumes.

### #114 — N-device consensus threshold

- **Shared status**: sequenced strictly after #116 (phase-machine
  convergence), which has not started, by both issues' own text and #117's
  explicit exclusion of this exact family from Android-parity work for the
  same reason.
- **Native-now**: implement the real threshold directly in iOS's existing
  `ScanPhase`/`SensingCoordinator` state machine, without #116.
- **Concrete rework cost**: this is the clearest violation candidate of the
  four. Two compounding costs, not one: (a) whatever ships natively-now
  becomes the new de facto oracle #116 must later match exactly — #116's
  own acceptance criteria already commit to a specific vector set
  (threshold-exact, reverse-order, duplicate-input, signal-loss-recovery)
  that would need to be re-derived from the native-now version, then
  reproduced bit-for-bit in `shared`; (b) this is squarely the kind of
  family the working manual treats as A/SWAP (current shipped behavior =
  oracle) — shipping a *new* native behavior right before the convergence
  work starts means the oracle moves mid-flight, adding spec-writing
  burden rather than removing it.
- **Recommendation: do not build for 8/20.** The decision record already
  accepted the current (first-detection) behavior as sufficient for
  real-device verification as recently as 2026-08-01 and 2026-08-03 —
  nothing about "iOS alone works end to end" requires changing it now. Land
  #116 only if slack remains after the critical path (§5); #114 stays out
  of 8/20 scope on the same "shared-authority-first" logic #117 already
  applies to Android.

### #139 — found: partial shared dependency (not one of the PM's named four, included because its own text declares it)

- Layers 1 (time-window filter) and 2 (majority display) already have
  their logic in `shared` (PR #161, 2026-08-08) — only native UI wiring
  remains, which is the same wiring task #100 needs (they share
  `.eventInfoHint` plumbing) rather than an independent native-vs-shared
  choice. Layer 3 (self-heal) is presentation-only with no shared
  dependency at all.
- **No separate recommendation needed** — folded into Track B's #100/#139
  node in §2 rather than re-analyzed as a fifth case, since there's no
  native-now-vs-wait fork here: the shared half is done, only adapter
  wiring is left, same as #142/#143's situation but already further along.

---

## 4. What #138 needs to be buildable

Given #141's event cards can only display events some device is
broadcasting (#138's sender side), and given the two constraints the
2026-08-09 ruling carried forward from the overridden 2026-08-06 decision:

1. **Spec revision** — `docs/specs/event-discovery.md` §9.a/§9.b needs a
   rewrite reflecting the override, before implementation starts (this
   repo's standing practice; the ruling itself names this as required
   follow-up work).
2. **A TLV-transport design decision for label + validity period** —
   B005's wire format structurally carries only two TLV types
   (`eventDisplayName`, `eventCodeHash`; confirmed both in DECISIONS
   2026-08-06 and independently in `event-discovery.md` §7). The
   2026-08-09 ruling flags this as unresolved: *"label/有効期間をどの経路
   で運ぶかは設計時に確定が要る"*. Three directions exist to choose among
   (not decided here): (a) a new Barnard TLV type/version — cross-repo,
   unknown lead time, and `event-discovery.md` §7 already noted new
   wire-format types need "an explicit privacy review and a new format
   version"; (b) overload the existing `eventDisplayName` field with a
   delimiter convention — cheap, no protocol change, but caps label length
   and is fragile; (c) keep label + validity period entirely local to the
   organizer's own device (an operational tag for venue staff, never
   transmitted) — the event's actual identity on the wire stays
   `eventDisplayName`/`eventCodeHash`, unchanged. (c) requires no protocol
   change and matches how #138 itself describes the label
   ("受付A" reads as staff-internal, not participant-facing), making it the
   cheapest starting point, but this is a design call for whoever owns the
   spec revision, not resolved here.
3. **A trust-signaling UI treatment** (carried-forward constraint 1) — a
   visible "beid does not vouch for this broadcast" element on the
   organizer screen (or the received card), consistent with DESIGN.md
   §15's no-overclaiming voice; needs a copy pass with translator
   `comment:`s across 5 locales per AGENTS.md.
4. **Barnard-repo-side protocol/signing readiness** — #138's own text
   places the protocol side in `levarac/barnard#122`/`#123`, a different
   repository. This document cannot verify readiness there; flagged as a
   real, unbounded risk to the estimate in §5.
5. **Parallelizable with #141 once 1–3 land**, but the two need each other
   for *end-to-end validation* (one device running #138 while others run
   #141) — hardware for this already exists per the 2026-08-01 decision (4+
   iPhones on hand).

---

## 5. Fit assessment against 11 days

**Estimates below are calibrated against this team's own recently observed
velocity, not generic industry estimates**: the 7 commits this session
found landed on `origin/main` (#146, #151, #153, #157, #159, #160, #161 —
roughly 4,300+ lines including new pure-function families with double-digit
mutation-tested vector counts, plus full native adapter wiring for two of
them) went in within about 6 hours of wall-clock time on 2026-08-08. That
pace is a real data point, not a guess, but it is a single burst — it says
nothing about sustained daily throughput, and it does not cover
judgment-heavy work (spec revisions, cross-repo coordination) the same way
it covers vector-tested code.

| Track | Item | Estimate |
|---|---|---|
| A | #155 (schema gate) | 0.5–1 day |
| A | #156 (owner-key regen fix) | 0.5–1 day |
| A | #91 sub-slice 3 only | 0.5–1 day |
| A | #158 (label rename + i18n) | 0.25–0.5 day |
| A | #131 (observability, soft) | 0.5 day if included |
| **A total** | | **1.75–4 days** |
| B | event-discovery.md §9 spec revision + TLV design decision + trust copy | 1–2 days |
| B | #138 implementation | 1–2 days **+ unbounded external Barnard-repo risk** |
| B | #100 native wiring | 0.5–1 day |
| B | #139 native wiring (layers 1–3) | 0.5–1 day |
| B | #141 (event-card UI) | 1.5–3 days |
| **B total** | | **4.5–9 days + external risk** |
| C | aggregation adapter wiring (untracked gap) | 0.5–1 day |
| C | #142 | 0.5–1 day |
| C | #143 | 0.5–1 day |
| C | #137 (reduced) | 0.5–1 day |
| **C total** | | **2–4 days** |

**Two scenarios, stated plainly, not padded to fit:**

- **Full parallelism across A/B/C** (enough concurrent capacity that the
  three tracks genuinely overlap): critical-path length ≈ the longest
  track, **Track B at 4.5–9 days + external risk**. This fits inside 11
  days with real margin — *if* the Barnard-repo dependency doesn't slip and
  *if* the team can actually run three tracks concurrently, which is a
  capacity assumption this document cannot verify.
- **Single-threaded / sequential** (one team driving all three tracks in
  order): total ≈ **8.25–17 days**, before any code-review overhead. This
  repo's own practice includes multi-round review as normal (e.g., #150
  notes *"#128 のレビューで4ラウンドかけて潰してきた"*) — that overhead is
  not included in the estimates above and would push the sequential
  scenario further past 11 days.

**Conclusion: does not reliably fit, stated plainly.** Even the optimistic
parallel scenario spends 40–80% of the entire 11-day budget on Track B
alone — the single largest, most novel (nothing like #138/#141 has been
built before in this repo), and most externally-dependent item in the
plan. The sequential scenario clearly does not fit. Given the real
uncertainty about actual parallel capacity and the unverifiable Barnard-repo
timing, the safer planning assumption is that it does not fit without cuts.

### Cut list, in priority order (cut top-down until it fits)

1. **#104** (Figma/UX-canonical visual audit) — cosmetic, not in the DoD at
   all; zero functional cost to cut. This also means explicitly not
   following the still-standing 2026-08-08 "issue consolidation → gh#104
   inventory" sequencing for 8/20 purposes — flagging that as something the
   PM should confirm rather than something this document resolves.
2. **#114 + #116** (N-device threshold + phase-machine unification) —
   already recommended deferred in §3 on independent grounds; effectively a
   pre-cut, not a new one.
3. **#133, #134, #136** (ledger durability edge cases) — each issue's own
   text states negligible risk at current usage scale.
4. **#131** (ledger observability) — cheapest remaining soft item, but not
   a free cut: this exact blind spot (silent failure, no `os_log`, no
   health signal) is what let both #146's and #157's predecessor bugs go
   unnoticed until an independent review went looking. Cut only if 1–3
   aren't enough.
5. **One of #142/#143** (not both) — both need the same adapter and
   dramatize different moments (live vs. daily-summary). If time is short,
   ship the adapter plus **#142 only** — its own text names it the demo
   script's centerpiece (*"デモの山場"*) — and defer #143 to just after
   8/20.
6. **#137** — cheap even before this cut list (its dependency already
   shipped), but least load-bearing of the three visibility issues:
   Collection/ItemDetail already surface proof state today, just not
   unified into one screen. Next to go if still short after 1–5.
7. **Trim #139's layer 3 (self-heal) and #138's reassignment-history
   requirement** to their minimum slices — ship #139 layers 1–2 without
   the self-heal safety net initially; ship #138 without history tracking.
   Add both back immediately after 8/20.
8. **Last resort — #138 itself.** If the Barnard-repo dependency isn't
   ready in time, #141's real (non-DEBUG) flow has no broadcaster to
   validate against end-to-end. Fallback, already partially sanctioned by
   the still-valid parts of `event-discovery.md` §6: ship #141's card UI
   wired only to the existing `DEBUG`-only dogfood toggle for internal
   validation, and **keep manual EventCode entry as the production
   fallback** a real user actually uses at launch (#101 stays fixed
   regardless — that's what makes a real, specific-event join still
   possible without #138). Ship #138's full production sender UI
   immediately after 8/20. This is the one cut that changes what "real
   participation" means for the 8/20 build, so it's listed last and should
   be a PM decision, not an automatic fallback triggered by this document.

---

## Concerns

- **This SubPM's local checkout was stale (7 commits behind `origin/main`)
  at the start of this task.** All figures above are grounded in
  `origin/main` as fetched and inspected via `git show --stat` against
  actual diffs, not the local tree or issue text alone. Recommend the PM
  confirm this SubPM's local checkout gets synced before any further work
  that depends on current repo state, to avoid this recurring.
- **The aggregation adapter-wiring gap (Track C, first row) has no open
  issue tracking it.** #109 is closed with only its shared-side half
  shipped, by its own commit message's admission. Recommend filing this
  explicitly rather than assuming it's implicitly covered by #142/#143.
- **The Barnard-repo-side dependency for #138 (`levarac/barnard#122`/`#123`)
  is unverifiable from within this repo.** This is the single largest
  unbounded risk to the 11-day estimate and this document cannot size it.
- Everything else: none.
