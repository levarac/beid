# Spec — Visibility & aggregation UI (#142, #143, #137 + #158)

Status: **APPROVED by PM** (2026-08-09, via SubPM a-20260809-002) — cleared
for implementation of #142, #137, #158. #143 is additionally gated on a
new foundational issue, **#166** ("Persist a computed session-aggregate
snapshot at session end (#143 foundation): nothing durable today can
rebuild a window/band series after a session ends", Track C — see
§4.2/§9), landing first; #143's UI design in this spec is approved, but
its implementation cannot start until that persistence work lands.
Owner (drafting): Worker a-20260809-009, for SubPM a-20260809-002.
Verified against `origin/main` @ `a6b270e` (2026-08-08), fetched fresh
2026-08-09 before drafting.

## 0. Why one spec, four issues

#142 (recording-view live mutual count), #143 (daily/session participation
summary), and #137 (transparency view) all display counts or series that
must come from `shared`'s `ObservationAggregation.kt` output, never from a
UI-side computation (AGENTS.md KMP contract, `docs/kmp-shared-foundation.md`
§2). #158 (renaming the currently-mislabeled "Peers verified"/"Devices
verified" strings) is a naming decision that touches copy in all three
surfaces plus `ItemDetailView`/`SignalLostView`, so it rides along here
rather than getting its own document. **Each of the four still closes as
its own separate implementation PR** — this is the single design document,
not four.

## 1. Source-of-truth precedence and hard constraints

Per DECISIONS 2026-08-08: **DECISIONS.md > UX 正本 (Notion press release)
> Figma > current code.** #142/#143/#137 are written against the UX 正本
and are independent-audit-sourced issues (per the same 2026-08-08 entry),
so their acceptance criteria carry real weight here — where this spec
proposes something the data cannot support, that is called out explicitly
rather than silently softened.

Hard constraints carried over from the task brief, restated here as the
spec's own rules:

- **Contributor Proof is undefined and out of scope.** DECISIONS
  2026-08-09 returned it to scope at the `shared` aggregation-family level,
  but it has zero implementation and no agreed UI definition. Nothing in
  this spec is Contributor Proof. The counts this spec uses
  (`deviceCount`, `mutualDeviceCount`, and friends) are the detected/mutual
  *device* counts from `ObservationAggregation.kt`, a different, already-
  landed value. If a future reader is tempted to fold Contributor Proof
  into one of these screens, that is a new spec, not an extension of this
  one.
- **Every displayed number is `shared`-derived.** No screen in this spec
  sums, filters, or recomputes raw observations/windows itself. Where the
  current codebase does that today (see §3.1's discussion of
  `SensingCoordinator.devicesVerified`), migrating it onto the shared
  aggregation call is part of the corresponding issue's scope, not a
  follow-up.
- **#137 degrades honestly.** See §5 — the actual data gap on the "参加記録"
  tier is larger than the issue text assumed (§5.2).
- **DESIGN.md forbidden terms and tone apply** (§15): no "on-chain", no
  "tamper-proof"/"trustless", sentence case, no exclamation marks, no
  claimed mutuality the data doesn't support.
- **Both-OS rule**: see §2.
- **Localization**: every new user-facing string is named with its
  parameterization and translator-comment needs in §7's inventory.

## 2. Both-OS statement (cite this, don't re-derive it)

Per AGENTS.md's current-state paragraph: Android has only the Event Join
screen, and `EventJoinCoordinator` stops at `Idle`/`RequestingPermission`/
`Sensing`/`PermissionDenied`. **There is no Android recording screen,
history screen, or transparency screen at all today** — the entire
post-join screen flow that #142/#143/#137 extend or create does not exist
on Android. This is the valid, named reason all three implementation PRs
ship iOS-only: not "Android deferred by choice" but "the Android surface
this would extend does not exist yet" (tracked separately at #121-and-
successors for Android production wiring). Each of the three implementation
PRs should cite this section rather than re-deriving the justification.

## 3. #142 — Recording view: live mutual-observation buildup

Issue: "記録中画面: 相互観測のリアルタイム積み上がり表示." Surface:
`ios/Beid/Views/RecordingView.swift`, the steady `.recording` phase of the
scan flow (`ScanFlowView` → `RecordingView`, DESIGN.md §11 "Scan flow").

### 3.1 What exists today vs. what changes

`RecordingView` today shows one native-computed number:
`sensing.devicesVerified` — a `SensingCoordinator`-local
`Set<String>`-backed count (`distinctPeerDisplayIds`,
`SensingCoordinator.swift:89,168`) of **all-observation** distinct
devices, already correctly keyed on `detectedDisplayId` (not the rotating
RPID) post-#154. This is real product behavior, but it is native-computed,
not shared-derived — it duplicates logic that
`SessionAggregate.deviceCount`/`WindowAggregate.peerCount` now own in
`shared`. Migrating this specific readout onto the shared aggregation call
is **in scope for #142's implementation**, not a separate follow-up: the
issue's own AC #2 ("表示値が shared の集計 API 由来であることがコードで確認できる")
requires it, and leaving `devicesVerified` as a parallel native
computation would be exactly the "two implementations disagree" drift
AGENTS.md's KMP contract forbids.

#142's own title is about a **different, currently-absent** number: the
**mutual**-scope buildup (`mutualDeviceCount`, `mutualObservationCount`).
This does not exist in the app today in any form.

### 3.2 Data read (per §109/#154 comment threads, all-observation scope
recapped in §6)

- Primary readout (replaces `devicesVerified`): `SessionAggregate
  .deviceCount` — all-observation, display-id-derived, lower-bound device
  count for the session so far.
- Secondary readout (new, the issue's actual subject):
  `SessionAggregate.mutualDeviceCount` and `.mutualObservationCount`.
- Window-by-window buildup visual: `SessionAggregate.windowAt(index:)` /
  the `WindowAggregate` series (`peerCount`, `mutualPeerCount` per window),
  read via `windowCount`/`windowAt`.
- Recompute cadence: **no subscription API exists or is planned** (#109).
  The adapter recomputes `aggregateObservationsForSession` on every new
  observation (session-sized observation counts make this cheap per
  #109's author) and republishes; `RecordingView` binds to a
  `@Published` property the adapter updates, the same pattern
  `devicesVerified` already uses.

### 3.3 Ruling: mutual count ships as an honest zero (PM, 2026-08-09)

**Ruled**, not merely flagged. Quoting DECISIONS.md in full (last entry in
the file at drafting time, dated 2026-08-09, titled "相互観測数は端末上では
0 のまま正直に表示する(捏造も概算もしない)"):

> 決定内容: #142 / #143 が表示する相互観測数(mutual)は、端末上では常に 0 として
> 正直に表示する。推定値・概算・「観測数で代用した相互数」は表示しない。ユーザーに
> 見せる主指標は全観測ベースの積み上がりとし、相互数はそれとは別の値として 0 のまま
> 置く。#142 の受け入れ基準①「2台の実機で相互カウントが数秒で上がる」は、端末単体
> では満たせない項目として扱い、成立判定は #144 の6段(post-8/20)へ送る
>
> 理由: プロトコルに相互性の信号が存在しない。`BarnardDetectionEvent` は「自分が
> peer を観測した」しか伝えず「peer が自分を観測し返した」を伝えないため、shared の
> `mutual` は呼び出し側が渡す入力であって推論できない。相互観測の成立は本来「二者
> の署名付き記録を検証者が突合する」ことで establish されるものであり、これは
> DECISIONS 2026-08-09 で post-8/20 と決めた #144 の4段目そのものである。端末側で
> 相互数を捏造すると、製品の中心的主張(相互観測に基づく出席証明)を裏付けの無い数字
> で先取りすることになる
>
> 決定者: PM(a-20260808-020。Track C が発見・報告し、PM が裁定)
>
> 帰結: 8/20 のビルドでは相互観測数が常に 0 と表示される。これは実装の不足ではなく、
> 突合が検証器側の仕事であることの正直な反映である。対外説明時にこの点を明示すること

This confirms and elevates from a recommendation to a binding rule
everything §3.3 (in the earlier draft) observed about the code: no native
caller can set `mutual = true` today because no reciprocity signal exists
anywhere in the protocol (`ObservationAggregation.kt`'s
`addAggregationObservation` doc comment: "Mutuality is decided by the
caller and is never inferred"). Establishing mutuality is properly the
verifier's job — stage 4 of #144's six-stage contract, already placed
post-8/20 by DECISIONS 2026-08-09 — not something an on-device estimate
should get ahead of.

**Binding consequences for implementation:**

- The mutual readout (`SessionAggregate.mutualDeviceCount`/
  `.mutualObservationCount`) displays as a literal `0` for the 8/20 build,
  always, honestly — never estimated, never substituted with the
  all-observation number.
- This is a real, honest `0` (every observation's `mutual` flag is `false`
  today), not the "missing data ≠ zero" sparse-window case from §6 — do
  not conflate the two. A missing window/band is drawn as an absent slot;
  a mutual count of `0` is drawn as a normal, present, zero-valued number,
  because that is what it actually is.
- The primary readout stays the all-observation buildup (§3.1's migration
  off `devicesVerified` onto `SessionAggregate.deviceCount`); the mutual
  line sits beside it as its own, separately-labeled, always-zero-today
  value.
- **#142's AC #1 is ruled deferred to #144 (post-8/20), not a failing
  criterion for this implementation.** Per the PM's explicit instruction,
  **the issue's AC text itself is not edited by this spec or its
  implementer** — a GitHub comment on #142 records this ruling and its
  reasoning instead, leaving the AC text visible as originally written so
  the issue author sees the change proposed as a comment, not silently
  applied.
- The visual/copy treatment in §3.4 and the localization guidance in §7
  are unchanged by this ruling — they already assumed an honest,
  always-zero-today mutual line; this ruling makes that binding rather
  than a recommendation.

### 3.4 Visual treatment

- Primary line: reuse the existing `recordingCaption` pattern
  (`RecordingView.swift:106-118`) — a `Text` inside the `EventCardView`
  caption slot, `DS.Font.meta` / `DS.Color.textSecondary`, next to the
  existing `ProgressView` (indeterminate, no denominator — unchanged).
  Content and string key change per §7.
- Secondary line (mutual buildup, new): a second `BeidMetricRow` inside the
  same `EventCardView` caption slot area, or a second line under the
  primary caption — label "Mutual confirmations" (naming per §7), value
  `mutualDeviceCount`. Pairs with `DS.Color.proofSeal` (the screen's one
  motif accent per DESIGN.md §5, already set via `.tint(DS.Color.proofSeal)`
  at `RecordingView.swift:92`) — no new color token needed.
- Window-by-window buildup ("窓 (ENIN) 単位の積み上がりが視覚的に分かること"):
  **no existing DESIGN.md component covers a per-window series
  visualization.** Proposal (flagged, needs design sign-off before
  implementation per DESIGN.md §11's "Agents MUST NOT improvise these"):
  a compact horizontal row of small dots, one per known window (reusing
  `DS.Size.statusDot` and `DS.Color.proofSeal`/`textSecondary` — no new
  tokens), filled for windows with `mutualPeerCount > 0`, outlined
  otherwise, capped to the most recent N windows with overflow indicated
  by a leading ellipsis-style fade. This is a **new component** and would
  need a DESIGN.md §10 entry in the implementing PR (component additions,
  unlike token additions, aren't gated by §4's ratification process, but
  DESIGN.md's own component-inventory convention expects an entry). If
  design sign-off prefers a simpler treatment (e.g., a plain "N windows
  recorded" text line, no visualization), that satisfies the issue's
  weaker reading of "見える" and needs no new component — recommend
  starting there and treating the dot-row as a stretch goal.
- Sparse-data handling: `SessionAggregate.windowAt(index:)` only returns
  present windows; a gap in ENIN sequence is a gap in the dot row, not a
  filled "0" dot. Do not zero-fill.

### 3.5 Acceptance criteria mapping

| #142 AC | Satisfied by |
| --- | --- |
| "2台の実機で相互観測が成立するたび、両画面の数値が数秒内に増える" | **Ruled deferred to #144 (PM, 2026-08-09, DECISIONS.md)** — see §3.3. Not a bar for this implementation; the mutual field displays an honest `0`. Plumbing is still verifiable with `mutual: true` test fixtures (the aggregation call itself updates correctly), but the on-device field demonstration is out of scope until #144's stage 4 lands. |
| "表示値が shared の集計 API 由来であることがコードで確認できる" | Adapter calls `aggregateObservationsForSession`; `RecordingView` reads only adapter-published `SessionAggregate`/`WindowAggregate` fields, no local `Set`/counter math in the view or `SensingCoordinator` (§3.1's migration). |

## 4. #143 — Participation record summary (daily/session)

Issue: "参加記録サマリー: 日次まとめと時間帯ごとの積み上がり (参加記録カード)." **New
surface** — no existing screen covers this (DESIGN.md §11 confirms no
daily-summary or transparency screen exists).

### 4.1 What data it reads

- Headline number: `SessionAggregate.mutualDeviceCount` (mutual-scope,
  session-wide) — same reciprocity caveat as §3.3 applies: **this will
  read `0` until a reciprocity signal exists.** #143's own comment thread
  on #109 (2026-08-08 correction) explicitly says this screen is "most
  affected" by the display-id-vs-rpid distinction but that the device-
  count math itself is fine post-correction; the mutual-vs-zero gap is a
  separate, later-discovered issue this spec is surfacing, not something
  #109's thread resolved.
- Time-band buildup: `SessionAggregate.bandAt(index:)` /
  `BandAggregate.deviceCount`, `.observationCount`,
  `.observationsWithoutDisplayIdCount` (all-observation scope) plus the
  `mutual*` triplet. Band width is supplied as a window count
  (`windowsPerBand`), never a duration — #143's screen must pick a
  band-count-to-time-label mapping itself (e.g. "the last hour" computed
  as `windowsPerBand × current ENIN window-length-in-seconds`); it cannot
  ask the aggregation API for "one hour" directly.
- Band anchoring: bands are anchored at absolute ENIN 0
  (`aggregateObservationsByBand`'s doc comment), not session start, so
  **the first band the UI ever sees for a session is very likely
  partial.** Render it as a normal band (its `deviceCount` etc. are
  correct for the partial span it covers), not specially flagged — a
  reader with real product judgment may want a "partial" label; that's a
  visual-polish decision left to implementation, not a data-correctness
  requirement.
- Per-issue AC "時間帯表示が窓 (ENIN) 単位の実データと一致する" was
  itself corrected by the issue author on #109 (2026-08-08, third
  correction comment): the requirement is that band rows are **derived
  from** the same observation set and window boundaries as the window
  rows, **not that the numbers are equal** — a band's `deviceCount`
  (display-id-based) and a window's `peerCount` (rotating-key-based) can
  legitimately disagree even at `windowsPerBand = 1`, because a peer with
  no display id counts in the window row but not the band row. §4's
  acceptance-criteria mapping table uses the corrected wording.

### 4.2 Persistence gap — ruled: tracked as issue #166 (Track C, PM 2026-08-09)

#143 is opened **after a session ends**, from history — by definition
after the live `SessionAggregate` the adapter was recomputing during
`.recording` has gone out of scope (the app may even have relaunched).
Rebuilding a `BandAggregate`/`SessionAggregate` series requires the full
per-observation input (`windowIndex`, `peerKey`, `displayId`, `mutual`)
that `AggregationObservationInput` accumulates — and **nothing in the
current persistence layer stores that.**

- `Proof` (`ios/Beid/Models/Proof.swift`) stores only a single rolled-up
  `peersVerified: Int` (soon renamed per #158), not a series.
- `WindowReportStore`/`WindowReport` (`ios/Beid/Persistence/
  WindowReport.swift`) stores one row per **closed** window with `enin`
  and a pre-aggregated `peerCount` — not per-observation `displayId` or
  `mutual` data, and (per its own doc comment) **open, in-progress-session
  windows aren't in it at all**, only windows that finished closing.

Neither store has enough raw material to recompute a `BandAggregate`
series after the fact. **This is a genuine gap this spec cannot close by
itself** — it's either a new persistence responsibility (capture
per-observation rows, or capture the computed `SessionAggregate` snapshot
at session end) or a native/adapter design decision, not a UI spec
decision.

**Ruled** (PM, 2026-08-09, via SubPM a-20260809-002): this gap is now
tracked as its own foundational issue, **#166** ("Persist a computed
session-aggregate snapshot at session end (#143 foundation): nothing
durable today can rebuild a window/band series after a session ends"),
owned by Track C under a separate Worker — not something this spec or its
implementer designs. Two points are binding on that issue, decided by the
PM rather than left for that issue's own author to re-decide:

- Persist the **computed `SessionAggregate` snapshot** (windows + bands +
  totals) at session end, keyed alongside the `Proof` it belongs to — not
  raw per-observation rows. The aggregation is a pure function of data
  that no longer changes once a session ends, so replaying raw rows later
  buys nothing over storing the already-computed result once.
- Follow the **unsent-window-ledger codec precedent**
  (`docs/kmp-shared-foundation.md` §5) for how the snapshot crosses the
  shared/native boundary: `shared` owns the portable snapshot format,
  native owns storage location and atomic write — the same split the
  ledger already uses.

The **session-end hook itself falls in Track A's territory**, per the
PM's sequencing ruling, and carries a hard sequencing/review requirement
before #143 can build on it. This spec's own scope stops at describing
what #143 needs to read (§4.1, §4.3) — it does not design the persistence
mechanism, which is #166's job. **#143's UI design in this spec is
approved; its implementation is gated on #166 landing first.**

### 4.3 Visual treatment

- Entry point: **no History/tab-bar screen exists yet** to open a summary
  "from history" per the issue's own phrasing. Recommendation: add an
  entry point from `ItemDetailView` (Screen 08, the durable per-proof
  screen) — e.g., a row or button "View participation summary" inside the
  existing `BeidPanel` metadata block or as a new panel below it, pushing
  the new `ParticipationSummaryView` (name TBD) via the same
  `navigationDestination(item:)` push pattern DESIGN.md §11 already uses
  for Detail. This reuses the existing IA (`CollectionHomeView` grid →
  `ItemDetailView` → new push) instead of inventing a tab bar or history
  list. **Flagged as an IA decision, not dictated** — the issue's AC only
  requires "opens from history," and `ItemDetailView` is this app's only
  existing "history" surface for a completed session.
- "参加記録カード" (a demo-presentable one-pager): reuse `EventCardView` at
  the top of the new screen (event name/venue, no new component), with the
  band-buildup visualization and headline mutual-device-count below it in
  a `BeidPanel`.
- Time-band visualization: same open proposal as §3.4's window dot-row,
  scaled to bands instead of windows — a simple stepped/bar treatment
  reusing `DS.Color.proofSeal` (no new tokens) is the safest starting
  point; anything more elaborate (an actual chart) is out of scope for
  this spec and would need its own design pass.
- Sparse handling: `BandAggregates.bandAt(index:)` only returns present
  bands. A gap (a period with no recorded observations — e.g. the user
  stepped away, or was mid-`.signalLost`) renders as a visible gap in the
  band row, never a zero-value bar. This is the literal mechanism behind
  the issue's own AC "遅刻・中断があっても記録された範囲がそのまま見える (無い時間を
  埋めない)."

### 4.4 Acceptance criteria mapping

| #143 AC | Satisfied by |
| --- | --- |
| "記録セッション終了後、当該イベントのサマリーが履歴から開ける" | New push destination from `ItemDetailView`, per §4.3 — **blocked on §4.2's persistence gap being resolved first.** |
| "時間帯表示が窓 (ENIN) 単位の実データと一致する" (corrected reading: *derived from* the same observation set/window boundaries, not numerically equal) | Band series comes from `aggregateObservationsByBand` over the same persisted observation input the window series would use; band/window disagreement at shared display-id coverage gaps is expected and documented in-UI, not hidden. |

## 5. #137 — Transparency view

**Status: approved as-is (PM, 2026-08-09, via SubPM a-20260809-002) — no
spec change required.**

Issue: "透明性ビュー: 参加操作/参加記録/検証済み参加証明の三状態を分離表示する." **New
surface**, three-tier vocabulary:

1. **参加操作** (join action) — did / did not join.
2. **参加記録** (participation record) — recorded on-device / sent to
   report server / included in published data.
3. **検証済みの参加証明** (verified proof) — passed third-party
   verification, including a pending state.

### 5.1 What data it reads

- Tier 1 (参加操作): `AppCoordinator`/`SensingCoordinator` state —
  `joinedEventCode` presence and/or `ScanPhase != .idle`, or simply the
  existence of a `Proof` for the event. No aggregation involved; this tier
  is a plain native state read, not a `shared` output.
- Tier 2 (参加記録), sub-state "端末内に記録済み" (recorded on-device): the
  **shared unsent-window ledger** is the correct source per
  `docs/kmp-shared-foundation.md`'s ownership table ("未送信台帳の状態と純粋な
  reducer" is a `shared` responsibility) — read the ledger's own closed/
  pending-window counts through `UnsentWindowLedgerRuntime`, **not** a
  native re-count of `WindowReportStore.reports` (which duplicates
  information the ledger already tracks and risks disagreeing with it).
  **Flagged as TBD-confirm-with-adapter**: whether `UnsentWindowLedgerRuntime`
  currently exposes a queryable "closed window count" or only imperative
  open/close/reconcile calls (`UnsentWindowLedgerRuntime.swift:14-23`
  shows only `openWindow`/`closeWindow`/`reconcileAfterRelaunch` — no
  read accessor). If it doesn't yet, exposing one is small additive scope
  for whichever PR implements this tier, not a redesign of the ledger.
- Tier 2, sub-states "送信済み" (sent) / "収録済み" (included in published
  data): see §5.2 — **no data source exists for either today.**
- Tier 3 (検証済みの参加証明): "third-party verification passed," including
  a pending sub-state driven by report-server receipts. **No data source
  exists** — see §5.2.

### 5.2 ⚠️ The real data gap is larger than the issue text assumed

The issue's own text says: "「収録済み」「確認待ち」は報告サーバの receipt (受理/
収録の二層) が入力になる。サーバ側が未実装の間は「送信済みまで」の最小形で成立させ" —
i.e., it assumes **送信済み (sent) already has, or will imminently have, a
real data source**, and only the two receipt-dependent sub-states
(収録済み/確認待ち) need to degrade.

That assumption does not hold against the current codebase. Grepping
`ios/Beid/` for network/submission code
(`submit|Submit|URLSession|report.*server|facilitator`) turns up nothing —
the only server-shaped code paths in the tree are wallet-connector RPC
(Coinbase/Reown/WalletConnect) and event-code entry, unrelated to report
submission. `WindowReport`'s own doc comment is explicit: **"no network
transport or batch/anchor pipeline exists yet"** (`WindowReport.swift:9`),
and `WindowReportStore`'s doc comment independently confirms it's "same
pattern as `ProofStore` (flat JSON, **no server call**)"
(`WindowReportStore.swift:15-16`). This matches DECISIONS 2026-08-09 ("8/20
の到達点は「iOS 単体で一通り動く」... 送信経路・検証器 ... は 8/20 後へ回す") — the
send path itself is explicitly post-8/20 scope, not merely
receipt-incomplete.

**So today, only the first sub-state of Tier 2 ("端末内に記録済み") has any
real data.** "送信済み," "収録済み," "確認待ち," and all of Tier 3 are
uniformly "not yet available" — not because of a receipt-format gap
specifically, but because the transport and verifier layers themselves
don't exist in this codebase yet.

This does not mean #137 should be dropped or that its acceptance criteria
are wrong — the honest-degrade principle the issue itself states ("収録/
確認待ちの半分は…absence reads as 'not yet available', never as a false
negative") applies uniformly to more of the screen than the issue text
anticipated. **Approved as-is (PM, 2026-08-09, via SubPM a-20260809-002)**: implement
the screen with tiers 1 and 2's first sub-state live, and every other
sub-state rendered as an explicit, honestly-labeled "not yet available"
state (§5.3) rather than inventing a fake sent/receipt signal to fill the
gap.

### 5.3 Visual treatment

- Three `BeidPanel` sections (one per tier), consistent with DESIGN.md's
  "Detail meta row" pattern (§10) — no section title inside the panel,
  rows go straight in, same as `ItemDetailView`'s existing Method/Devices/
  Status panel.
- Live sub-states (Tier 1 join action, Tier 2 "端末内に記録済み") pair
  `checkmark.circle.fill` + `DS.Color.proofSeal`, same as
  `ItemDetailView`'s existing Status row precedent (`ItemDetailView.swift
  :80-83`) — reuse, no new token.
- "Not yet available" sub-states (everything else): a neutral, non-
  alarming pairing — `DS.Color.statusOff` (already scoped in DESIGN.md §5
  as "a neutral toggle state... not an alarm," which is exactly the
  semantics needed here — this is not a failure or a degraded signal, it's
  a feature that doesn't exist yet) + an outlined `circle` glyph +
  explicit text (never color alone, DESIGN.md §2.9). **Do not reuse
  `DS.Color.signalWarning`** — that token is scoped to degraded/lost BLE
  signal specifically (§5's color table forbids using it for anything
  else), and a not-yet-implemented backend is not a signal problem.
  **Do not reuse `DS.Color.statusCaution`** either — that's scoped to
  failed/declined/timed-out wallet signatures, a different failure mode
  that implies something was attempted and didn't work; nothing has been
  attempted here.
- **Do not reuse `ItemDetailView`'s existing "Verified" status row or its
  copy/color for Tier 3.** That row's "Verified" claim is deliberately
  about local BLE self-evidence (DECISIONS 2026-07-28 OD-2: "全 Proof は
  BLE 検証済で正確"), a different and already-true claim from Tier 3's
  "passed third-party verification" — copying that row's green checkmark
  onto Tier 3 would overclaim a verification that has not happened. Tier
  3 needs its own, currently-always-"not yet available," presentation.

### 5.4 Acceptance criteria mapping

| #137 AC | Satisfied by |
| --- | --- |
| "記録/送信/収録/確認待ちが1画面で区別できる" | All four sub-states render as visually distinct rows on one screen — three are honestly "not yet available" today (§5.2), which is itself a form of being "区別できる" (distinguishable from the live one), not a failure to satisfy the AC. |
| "表示値はすべて shared 台帳・receipt 由来で、UI側での再計算がない" | Tier 2's live sub-state reads the shared ledger's own state (§5.1, pending the TBD read-accessor); no sub-state is UI-computed from raw observations. |

## 6. Sparse-data handling (shared rule, all three surfaces)

Recapped once here because it governs §3, §4, and §5 identically:

- **Missing ≠ zero.** `WindowAggregates`/`BandAggregates` return only
  windows/bands with data — "a missing window means 'nothing recorded'"
  (`ObservationAggregation.kt:63`), and the same for bands (`:111`). No UI
  in this spec zero-fills a gap into a dense series; a gap renders as an
  absent slot (§3.4, §4.3).
- **Never sum across windows/bands.** A peer present in two windows counts
  once in each; summing produces (device × window) inflation, exactly the
  #154 bug (`ObservationAggregation.kt`'s doc comments on `WindowAggregate`
  and `BandAggregate` both call this out explicitly). No screen in this
  spec adds window or band counts together.
- **Two scopes, always both present in the type, never both meaningful
  today.** Every count exists at both all-observation and `mutual*`
  scopes. The mutual scope is real, shared-derived output — but reads as
  `0` everywhere today because no native caller can set `mutual: true`
  (no reciprocity signal exists in the protocol, §3.3). This is expected,
  not a bug, and not the same thing as "missing data."
- **`deviceCount`/`mutualDeviceCount` are lower bounds.** The display id is
  4 bytes; a collision is possible though unlikely at event scale. No
  screen in this spec presents either as an exact figure.
- **Band width is windows, never seconds.** ENIN window length is a
  runtime parameter (default 300s, clamped 12-3600), not a constant — a
  screen that wants "the last hour" must compute
  `windowsPerBand = 3600 / currentWindowLengthSeconds` itself; the
  aggregation API has no seconds-based entry point.
- **Band anchoring is absolute ENIN 0.** `bandIndex = windowIndex /
  windowsPerBand`, anchored at 0, not session start — so a session's first
  band is normally partial (§4.1).

## 7. Localization string inventory

New/changed user-facing strings across #142/#143/#137/#158. All are
authored in English per AGENTS.md's process; `ja`/`zh-Hans`/`es`/`fr`
translations (machine-drafted, `needs_review` state) land in the same PR
as each string.

| Screen | String (English default) | Key form | Parameterized? | Translator comment needed? |
| --- | --- | --- | --- | --- |
| #158 rename | "Devices sensed" (was "Devices verified"/"Peers verified") | Explicit key (already reused across `ItemDetailView` + `SignalLostView` today as a literal — **this reuse is existing debt**; #158's PR should convert it to an explicit reverse-DNS key, e.g. `detail.devicesSensed.label`, per AGENTS.md's "about to write the same `Text(...)` in a second place" rule) | No | Yes — must state it counts distinct nearby *devices*, not people/peers, and does not imply mutual/reciprocal confirmation (existing `"Devices verified"` comment at `Localizable.xcstrings:651` is a good template to adapt) |
| RecordingView (#142, #158) | "Recording your attendance automatically · {n} devices sensed" | Existing key `scan.recording.caption`, keep key, update `defaultValue` | Yes (`%lld`) | Yes — same non-mutuality warning as today's comment (`RecordingView.swift:116`), carried forward |
| RecordingView (#142, new) | "Mutual confirmations: {n}" (or similar — exact wording TBD with SubPM given §3.3's caveat that this reads 0 today) | New explicit key, e.g. `scan.recording.mutualCount` | Yes (`%lld`) | Yes — must explain this is a distinct, currently-always-zero count pending a reciprocity signal, so a translator doesn't "simplify" it into a synonym of the devices-sensed line |
| #143 new screen | Screen title, e.g. "Participation summary" | New explicit key | No | No (self-evident) |
| #143 new screen | Headline metric label, e.g. "Devices mutually confirmed" (subject to §4.1's reciprocity caveat) | New explicit key | No | Yes — same reciprocity caveat as the RecordingView mutual line |
| #143 new screen | Time-band section label / per-band captions (exact copy TBD with visual design) | New explicit key(s) | Likely yes (band time-range) | Yes — must state that a gap in the band row means "not recorded," not "zero present" |
| #143 entry point | "View participation summary" (or similar, `ItemDetailView` link/button) | New explicit key | No | No |
| #137 new screen | Screen title, e.g. "Transparency" | New explicit key | No | No |
| #137 new screen | Tier labels: "Participation", "Participation record", "Verified proof" (English glosses of 参加操作/参加記録/検証済みの参加証明) | New explicit keys | No | Yes — each needs a comment fixing its exact scope so translators don't conflate "Participation record" (Tier 2, on-device/sent/included) with "Verified proof" (Tier 3, third-party verification) |
| #137 new screen | Sub-state labels: "Recorded on device", "Sent", "Included in published data", "Not yet available" | New explicit keys ("Not yet available" is reused across ≥3 rows — must be an explicit key from the start, not a literal, per AGENTS.md's reuse rule) | No | Yes for "Not yet available" — must state it means "this capability doesn't exist yet in the product," not "attempted and failed" (distinguish from error/warning copy elsewhere) |
| DESIGN.md §10 | "Detail meta row" component entry text ("Method", "Peers verified", "Status") | N/A — doc prose, not a String Catalog entry | N/A | N/A — update alongside #158's code change, same PR |

Housekeeping note (not blocking, flagged for whoever next touches this
region of the catalog): `"%lld of %lld peers verified"` and
`"scan.verifying.peersVerifiedCount"` (`Localizable.xcstrings:5-30`) are
orphaned — no code references either key (confirmed by grep). They predate
the Slice-2 merge of `VerifyingView`/`VerifiedView` into `RecordingView`.
Pruning them is optional cleanup, not part of #142/#143/#137/#158's scope.

### Re-translation cost (per #158)

`"Devices verified"` already has four populated `needs_review`
translations (`es`: "Dispositivos verificados", `fr`: "Appareils
vérifiés", `ja`: "確認済みの端末", `zh-Hans`: "已验证设备") — all four use
the target language's word for "verified," the exact term #158 exists to
retire. Same for `scan.recording.caption`'s four `needs_review`
translations (all contain "確認済み"/"verificados"/"vérifiés"/"已验证").
**Approved (PM, 2026-08-09, via SubPM a-20260809-002)**: since the verb
itself changes meaning (verified → sensed/detected), not just the
surrounding sentence, this needs actual re-translation, not merely a
re-review pass with the old translated text reused. Under AGENTS.md's
key-convention rule this also means introducing a **new explicit key**
rather than keeping the same key with new English — the old key's
existing translations would otherwise silently keep showing stale
"verified" wording in `needs_review` state until someone manually
re-translates, which is a worse failure mode (looks re-reviewed but isn't)
than a fresh key falling back to English until translated. "Devices
sensed" is the approved display name, and the new-explicit-key approach is
approved as proposed — not reusing `"Devices verified"`'s key.

### DESIGN.md §14 correction

#158's issue text says the row name lives in "DESIGN.md §14." As of this
verification, the actual occurrences are in **§10** ("Detail meta row"
component entry, `DESIGN.md:542`) and **§13** (Accessibility, the
VoiceOver string example at `DESIGN.md:668-670`). §14 is "Dark Mode and
High Contrast" and does not mention this string. Flagging so the
implementer doesn't search the wrong section. (Historical §17 Appendix C
decision-log entries also mention "Peers verified" in past tense,
documenting what was decided *at that time* — recommend leaving those
entries' wording alone, consistent with how DECISIONS.md is append-only;
only §10's current contract text and §13's current string need updating.)

## 8. Adapter data contract (cross-surface summary)

For whoever implements the iOS adapter (#162, a-20260809-008's parallel
task, "iOS adapter for the shared aggregation API (#109 follow-up):
SensingCoordinator still owns the device-count decision natively") —
this is what each of this spec's three surfaces needs, not a redesign of
the adapter itself. **Marked TBD-confirm-against-adapter** where the
adapter's own issue wasn't available at drafting time.

| Surface | Shared call | Fields consumed | Scope |
| --- | --- | --- | --- |
| #142 RecordingView, primary | `aggregateObservationsForSession` | `SessionAggregate.deviceCount` | all-observation |
| #142 RecordingView, secondary | same call | `SessionAggregate.mutualDeviceCount`, `.mutualObservationCount` | mutual (reads 0 today, §3.3) |
| #142 RecordingView, window buildup | same call | `SessionAggregate.windowAt(index:)` → `WindowAggregate.peerCount`/`.mutualPeerCount` | both |
| #143 summary, headline | `aggregateObservationsForSession` (recomputed at session end, then **persisted as a snapshot** — §4.2 gap) | `SessionAggregate.mutualDeviceCount` | mutual (reads 0 today) |
| #143 summary, band buildup | same | `SessionAggregate.bandAt(index:)` → `BandAggregate.deviceCount`/`.observationCount`/`.observationsWithoutDisplayIdCount` + `mutual*` triplet | both |
| #137 Tier 2 "on-device" | shared unsent-window ledger (`UnsentWindowLedgerRuntime`, not the aggregation API) | TBD-confirm: a read accessor for closed/pending window counts — not yet exposed on the runtime protocol as of `UnsentWindowLedgerRuntime.swift:14-23` | N/A (ledger state, not aggregation) |
| #137 Tiers 2 (sent/included) and 3 | none — no data source exists (§5.2) | — | — |

Recompute trigger for #142/#143's live portion: **no subscription API** —
adapter recomputes on every new observation and republishes via
`@Published`, matching the pattern `SensingCoordinator.devicesVerified`
already uses today (`SensingCoordinator.swift:462`).

## 9. Open questions / flags for SubPM (summary)

Consolidating everything flagged above, so it isn't buried in prose:

1. **§3.3** — **Ruled (PM, 2026-08-09, DECISIONS.md "相互観測数は端末上では 0 の
   まま正直に表示する")**: mutual count ships as an honest, always-zero value
   for the 8/20 build; #142's AC #1 is deferred to #144 (post-8/20), not a
   failing criterion for this implementation. A GitHub comment on #142
   records the ruling; the issue's AC text itself stays untouched.
2. **§4.2** — **Ruled (PM, 2026-08-09)**: #143's persistence gap is now
   tracked as its own foundational issue, **#166**, owned by Track C.
   Binding on that issue: persist the *computed* `SessionAggregate`
   snapshot at session end (not raw rows), following the unsent-window-
   ledger codec precedent; the session-end hook itself sits in Track A's
   territory with a hard sequencing/review requirement. #143's UI design
   in this spec is approved; its implementation is gated on #166
   landing first.
3. **§4.3** — #143's "opens from history" entry point is proposed as a new
   link inside `ItemDetailView`, since no History/tab-bar screen exists.
   Flagged as an IA choice, not dictated. (Still open — no PM ruling on
   this specific point.)
4. **§5.2** — **Approved as-is (PM, 2026-08-09)**: #137's real data gap is
   larger than the issue text assumed — "送信済み" has no data source
   either, not just the receipt-dependent sub-states. Implement tiers 1
   and Tier 2's first sub-state live, everything else as an explicit "not
   yet available" state.
5. **§5.1** — `UnsentWindowLedgerRuntime` may need a small additive read
   accessor (closed/pending window count) that doesn't exist today;
   TBD-confirm this is in scope for #137's implementation rather than a
   separate ledger-API PR. (Still open — no PM ruling on this specific
   point.)
6. **§7** — **Approved (PM, 2026-08-09)**: #158 introduces a new explicit
   key rather than reusing `"Devices verified"`'s key, given the
   verb-level meaning change makes the existing four `needs_review`
   translations actively wrong, not just unreviewed. "Devices sensed" is
   the approved display name.
7. **§3.4/§4.3** — the window/band buildup visualization is an unratified
   new component (a dot/step row). Recommend starting with a plain text
   fallback ("N windows recorded") and treating the visual as a stretch
   goal pending design sign-off, per DESIGN.md §11's "agents MUST NOT
   improvise new surfaces."
8. **§8** — the iOS adapter Worker's issue is now filed as **#162**
   ("iOS adapter for the shared aggregation API (#109 follow-up):
   SensingCoordinator still owns the device-count decision natively").
   The field/scope mapping in §8 is this spec's best understanding of
   `ObservationAggregation.kt`'s actual API; reconcile against #162's own
   text before or during implementation, since #162 wasn't available to
   cross-check at drafting time.
