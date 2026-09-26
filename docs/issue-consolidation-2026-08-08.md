# Issue consolidation — 2026-08-08

Produced by SubPM a-20260808-026 for PM a-20260808-020. This is a **map and
recommendation document, not a ruling**. Nothing in this file has been acted
on — no issue was opened, closed, edited, labeled, or commented on.

Source-of-truth used throughout: `<private-project-records>/DECISIONS.md`,
read in full. Per the hierarchy that document itself states as of
2026-08-08: **decision record > UX canonical source (Notion press release,
linked from #141) > Figma > current code.**

**Count discrepancy, flagged up front:** the task described "64 open
issues." A `gh issue list --repo thegreeting/beid --state open` query run
at the start of this work returned **66** open issues. All 66 are inventoried
below; none were excluded. The gap in the issue-number sequence (#146,
#151) is not missing data — those numbers belong to two already-merged PRs,
not issues.

---

## 1. Inventory — all 66 open issues

Strand key: **kmp** = KMP shared foundation (umbrella #106) · **android** =
Android feature parity (umbrella #117) · **ux-audit** = independent audit
against the UX canonical source · **ledger-quality** = unsent-window ledger
durability/observability defects · **ci** = CI cost/correctness ·
**pre-0806-legacy** = pre-existing queue, filed before the 2026-08-06 wave ·
**other** = doesn't fit the above.

| # | Title | One-line ask | Strand |
|---|---|---|---|
| 23 | DESIGN.md §11 rescue-path surface must not collide with EventCodeEntryView's onboarding route/copy | Flag: a future §11 rescue-path surface must not reuse EventCodeEntryView's route/copy as-is | pre-0806-legacy |
| 24 | DESIGN.md §15 sentence-case CTA rule still PROPOSAL | Ratify or drop the sentence-case CTA rule, then sweep all shipped CTA copy for consistency | pre-0806-legacy |
| 25 | BarnardRpidGenerator.joinEvent persists eventCode to UserDefaults with no leaveEvent() | Add a clear/leave path for the persisted manually-entered eventCode | pre-0806-legacy |
| 33 | wallet署名ペイロード (AttendanceProof/v1) は仮のもの | Placeholder wallet-signature payload isn't wired to the protocol's per-event-key/self-proof design; decide if wallet key becomes the account key | pre-0806-legacy |
| 36 | Reown Cloud projectId の登録 (Ken 手動) | Ken registers a Reown Cloud projectId so real WalletConnect pairing can be E2E verified | pre-0806-legacy |
| 38 | device-lab (emi) の beid ハーネス作り直し | Rebuild the device-lab Android harness for gradle + 2-device instrumented BLE tests | android |
| 46 | WalletConnector 抽象化 + CoinbaseConnector 実装 | Abstract WalletConnector and add a Coinbase connector, no projectId required | pre-0806-legacy |
| 50 | UI 洗練ラウンド follow-up 3 件 | Three deferred PR #49 UI-polish follow-ups (previews, status-text tokens, dark contrast) | pre-0806-legacy |
| 53 | 起動即センシングへの UX 再設計 | Redesign onboarding/home around launch-immediate sensing: drop Welcome, auto-start, add a transparency view | pre-0806-legacy |
| 55 | リリース体制の整備 | Stand up release-branch model, version discipline, CI guards for store submissions | ci |
| 60 | ENIN 単位の報告パイプラインと署名・binding の実装 | Implement the ENIN-window report pipeline: scheduler, unsent ledger, per-window signing, binding message | pre-0806-legacy |
| 61 | MetaMask 接続を DEBUG 限定から昇格させる条件 | Define the gate conditions before MetaMask leaves DEBUG-only | pre-0806-legacy |
| 62 | センシング中の Live Activity 表示 | Show a Live Activity while sensing is active/backgrounded | pre-0806-legacy |
| 63 | アプリ内ウォレット経路の検討 (backlog) | Backlog: evaluate an in-app wallet path for users without an external wallet | pre-0806-legacy |
| 76 | UIテストのテストロケール固定 | Pin UI-test locale/region to stop locale-dependent flakiness | ci |
| 77 | DeviceSecret を Keychain/iCloud 化 | Move DeviceSecret out of plain UserDefaults into Keychain/iCloud | pre-0806-legacy |
| 78 | TestFlight: Internal Build 完了後の ASC Dev グループ配信確認 | Confirm Internal Build artifacts actually reach the ASC Dev TestFlight group | ci |
| 79 | connect+binding interstitial の Figma sign-off | Get Figma sign-off for the connect+binding interstitial and two other screens | pre-0806-legacy |
| 80 | 非blocking 技術負債 3件 + 旧 Flutter 残骸撤去 | Three small tech-debt follow-ups plus removal of the old Flutter Runner.xcodeproj | pre-0806-legacy |
| 81 | タイムライン可視化 / per-event wallet 管理 / データ所有 (backlog) | Backlog: spec and build timeline visualization, per-event wallet mgmt, data-ownership UX | pre-0806-legacy |
| 82 | 履歴ドリルダウン IA Proof Detail 01b-05 プラス 02b-d、Token ID | History drilldown IA + Token ID; blocked on census expansion | pre-0806-legacy |
| 91 | セッション終了処理の取りこぼし2件 | Fix: last open window never persists; force-quit after binding can permanently lose the self-proof | pre-0806-legacy |
| 93 | PR Build & Test がコードのみの PR で起動せず | Xcode Cloud PR gate silently skips code-only PRs — merge gate passes without compiling/testing | ci |
| 100 | イベントへの参加経路が未設計 | Design the event-participation path end-to-end (code distribution, organizer role, serving UI, name/venue provenance); adopts B005 | other |
| 101 | 出荷ビルドでイベントコードが設定不能 | Shipped builds can never set a real event code — every user falls back to "beid-demo-event" | other |
| 104 | 実装が Figma と一致していない | Inventory every screen's drift from the Figma reference and classify each as intentional/gap/stale-Figma | other |
| 106 | ☂️ KMP shared foundation を導入 | Umbrella: introduce a KMP `shared/` module as single cross-platform authority for event/ledger logic | kmp |
| 108 | Registry response decode / EventDefinition / DelegationCert / report signing payload を shared に | Define registry-decode, EventDefinition, DelegationCert, report-signing-payload contracts in `shared` | kmp |
| 109 | Derived-value aggregation と discovered-event candidate scoring を KMP authority に | Move mutual-count/rollup/Contributor-Proof/anchor-edge aggregation + candidate scoring into `shared` | kmp |
| 110 | KMP shared 変更を両 platform で検証 | Verify KMP shared changes on both platforms; require resolved-dependency evidence in build claims | kmp |
| 112 | Android app モジュールに単体テストが存在しない | Android `app` module has zero unit tests; `testDebugUnitTest` passes vacuously (NO-SOURCE) | android |
| 114 | eventFound が最初の 1 検知で発火する | `eventFound` fires on first single detection, not an N-device consensus threshold, on both OSes | kmp |
| 116 | センシングのフェーズ判定を shared に | Move sensing-phase-machine judgment into `shared` so iOS/Android agree on "event detected" | kmp |
| 117 | ☂️ Android を iOS と同等の機能水準へ | Umbrella: bring Android to iOS feature parity | android |
| 118 | Android にアーキテクチャ層とテスト基盤を用意する | Give Android a ViewModel layer and a working Compose test setup | android |
| 119 | デザインシステムのコンポーネント群を Compose へ移植 | Port the 12 iOS design-system components to Compose | android |
| 120 | Android にセンシングのフェーズ表示を実装する | Implement sensing-phase display on Android | android |
| 121 | Android に記録の永続化と一覧画面を実装する | Implement record persistence and a list screen on Android | android |
| 122 | Android に記録の詳細画面と署名状態の表示を実装する | Implement a record detail screen with signature-state display on Android | android |
| 123 | Android にオンボーディングの各画面を実装する | Implement Android onboarding screens | android |
| 124 | Android にウォレット接続を実装する | Implement wallet connect on Android | android |
| 125 | Android に owner key の binding と self-proof を実装する | Implement owner-key binding and self-proof on Android | android |
| 126 | Android にアカウント / 設定画面を実装する | Implement an Android account/settings screen | android |
| 127 | イベント参加の失敗が「権限エラー」として表示される | `EventJoinCoordinator` reports every non-permission join failure as `PermissionDenied` | android |
| 128 | PR CI のテストが 1 本 50〜150 秒 | Debug-build secp256k1 signing burns real wall-clock time in tests; needs a fake-signer seam | ci |
| 129 | PR Build & Test の test destination が 4 台展開 | "Recommended iPhones" quadruples test billing for a suite with no UI-layout tests | ci |
| 130 | 計測シートを閉じたときにセンシングを止めるべきか | Decide (don't default) whether closing the measurement sheet should stop BLE sensing | other |
| 131 | 台帳の劣化が出荷ビルドから一切観測できない | Ledger failure paths are all bare `print()` — no way to observe degradation in shipped builds | ledger-quality |
| 132 | 台帳のウィンドウ登録に失敗すると報告が永久に漏れる | A failed ledger window-open silently and permanently drops that window's report | ledger-quality |
| 133 | 台帳の耐久性と後始末の積み残し 3 件 | iOS lacks Android's fsync; quarantined corrupt files never get pruned; 100k-record cap kills the ledger silently | ledger-quality |
| 134 | 起動時とウィンドウ確定時に、メインスレッドで同期的にファイル入出力 | Startup/window-close ledger I/O runs synchronously on the main thread, worsens with record count | ledger-quality |
| 135 | 証明・binding・self-proof のストアは、ファイルが壊れると黙って中身を捨てる | ProofStore/BindingRecordStore/SelfProofStore silently discard contents on decode failure, then overwrite | ledger-quality |
| 136 | 台帳が「もう何もできない状態」になっても復旧しない | A ledger snapshot at `revision = Long.MAX_VALUE` decodes fine but can never advance; no recovery path | ledger-quality |
| 137 | 透明性ビュー: 参加操作/参加記録/検証済み証明の三状態を分離表示 | Add a transparency view: participation action / participation record / verified proof as 3 distinct states | ux-audit |
| 138 | 会場端末モード: イベント情報ブロードキャストの運営側 UI | Add an organizer-facing "venue device" UI to start/stop broadcasting event info, with required label + validity period | ux-audit |
| 139 | 参加経路のいたずら対策 3 層 | Add 3 defensive UX layers vs. spoofed event broadcasts: time-window filter, majority display, post-join self-correction | ux-audit |
| 140 | 画面ロック時の相互観測成立率を実機測定する | Measure real-device mutual-sensing success rate with the screen locked | ux-audit |
| 141 | 参加サーフェスをイベントカード方式へ置き換える | Replace participation surface with auto-matched event cards; zero-tap auto-start; retire EventCode entry | ux-audit |
| 142 | 記録中画面: 相互観測のリアルタイム積み上がり表示 | Show a live real-time tally of mutual observations during recording | ux-audit |
| 143 | 参加記録サマリー: 日次まとめと時間帯ごとの積み上がり | Add a daily participation summary ("record card") with time-band buildup | ux-audit |
| 144 | 参加証明の成立条件を end-to-end の受け入れ契約として固定する | Fix, as one contract, the 6-stage rule set turning two signed observations into one certified result | ux-audit |
| 145 | 公開データのプライバシー制約: 名簿・接触グラフ・識別子を作らせない設計 | Design public-data schema's privacy constraints so re-aggregation can't reconstruct a contact graph | ux-audit |
| 147 | Release ビルド・実機での 1 署名の実測 | Measure real-device Release-build signing latency at window boundaries, check for UI jank | ci |
| 149 | 受入基準「テストが 5 分以内」が何を測るのか未定義 | #128's "5 min" acceptance bar is ambiguous ~4x depending what's measured; needs a precise definition | ci |
| 150 | testBarnardFacadeForwardsDistinctSelfProofRange は前提が崩れると無言で無意味になる | A regression test's invariant is unasserted; could silently stop testing anything | ci |
| 152 | AGENTS.md の PR CI 記述が workflow から静かにずれうる | AGENTS.md's PR CI description can drift from the real workflow file with nothing to catch it | ci |

---

## 2. Overlap map

### 2.1 Participation surface — #100, #101, #53, #141 (+ #139 found)

**Confirmed overlap, with a clear hierarchy, not a flat duplicate set.**

- **#141** is the newest and most concrete: replace the participation
  surface with auto-matched event cards, zero-tap auto-start on a clear
  majority, a rare manual-selection UI backed by relay-count display, and
  explicit retirement of the EventCode-entry screen as the primary path.
  Its own text states it resolves #101 as a byproduct: *"EventCode 入力画面
  の退役...#101 のフォールバック問題もここで解消"*. This checks out
  mechanically — #101's bug is that the only route into `EventCodeEntryView`
  (via `WalletConnectView.skipWalletForEventCode()`) is unreachable because
  `OnboardingMode.current` is hardcoded to `.guestFirst`; if EventCode entry
  stops being the primary join path at all (per #141), the specific
  unreachable-route bug in #101 is moot for the shipped flow.
- **#100** is the broader design-decision issue that #141 partially
  resolves. #100 lists 5 open design questions; #141 concretely answers
  question 1 (code distribution — answer: none needed, cards come from
  registry-matched B005 hints). #100's remaining open questions (organizer
  role, sender UI, name/venue provenance, sequencing) are picked up by
  **#138** (organizer/sender UI — see the conflict in §3 below) and by the
  already-resolved `docs/specs/event-discovery.md` §9.a/§9.b rulings, not by
  #141.
- **#53** (2026-07-23, pre-0806-legacy) is the oldest and broadest: its
  target-flow item 1 ("起動: 未接続なら wallet connect を要求") **conflicts**
  with the 2026-07-26 event-first decision (see §3 below) and should be
  treated as stale on that point. Its items 2 (auto-start, no manual "Sense
  Event" tap) and 3 (remove Welcome) are subsumed by #141's zero-tap design.
  Its item 5 (transparency view) is subsumed by #137, which is the
  UX-canonical-grounded, fully-specified version of the same ask.
- **#139**, not in the PM's original cluster list but explicitly
  cross-referenced by #141 itself (*"#139 の実勢表示と連携"*), belongs in
  this same cluster: its "majority display" layer is the literal mechanism
  #141's rare-selection UI depends on.

**Recommendation direction:** #141 and #139 together are the living design
for this surface; #100 becomes the tracking/rationale issue for the parts
#141 doesn't cover (organizer role, sequencing); #101 closes once #141 ships
(or earlier, as a standalone minimal fix, at PM's discretion — see §4);
#53's transparency-view scope folds into #137 and its stale wallet-first
flow item should be struck or the issue closed in favor of #141.

### 2.2 Report pipeline and acceptance contract — #60, #144, and the unfiled send-path/verifier work

**Confirmed overlap, at different layers, plus a confirmed filing gap.**

- **#60** (2026-07-23) is the original client-implementation ticket:
  scheduler, unsent ledger, per-window signing, binding message, multi-wallet
  memory. Its own pinned header already flags it as partially stale: *"本文
  だけを読んで実装しないこと"* — the binding-message design was superseded by
  the owner-key model (2026-07-30 comment) and by the KMP shared/native split
  (2026-08-06 comment, umbrella #106). Cross-checking its remaining scope
  against what's since shipped: the "未送信台帳" (unsent ledger) it asks for
  is the same ledger #131-#136 are now filing defects against — i.e. that
  part has been built. What has **not** been built, and is not covered by
  any other open issue, is the actual network send call itself (client →
  report server).
- **#144** (2026-08-07, ux-audit) is a documentation/contract issue, not an
  implementation issue: it asks for one end-to-end acceptance contract (sign
  → cross-match → derive, 6 stages, owners named per stage) precisely
  *because* no such document exists today. Its own background section names
  #60 (report) alongside sensing (#53) and aggregation (#109) as the
  scattered pieces it wants unified — #144 is aware of #60, not duplicating
  it blindly.
- **The send-path/verifier gap is real and independently confirmed.**
  DECISIONS 2026-08-06 *"8/20 までのスコープに送信経路・検証器を含める / 再開
  は gh#104 の棚卸しから"* states plainly: *"未解決: 送信経路・検証器の issue
  が未起票。スコープに含めると決めた以上、再開後に起票と spec が要る"*. This
  session's inventory confirms that note is still accurate — none of the 66
  open issues implements the report-server submission call or a verifier
  service. #108 (kmp) explicitly places "blob upload と facilitator API" in
  "platform / 別 repo が所有するもの" (out of `shared`'s scope, owned
  elsewhere) and does not itself file the elsewhere-work. No `docs/specs/*`
  file for a report server or facilitator exists either (checked the full
  `docs/specs/` directory).

**Recommendation direction:** #60 should be re-scoped to just its one
still-live piece (send-trigger wiring against the already-built ledger) or
closed with its shipped parts credited to #91/#131-136/#108-109; #144 should
be treated as the new authoritative contract that #60's remaining scope, the
still-unfiled send-path+verifier work, and #108/#109 must all conform to;
the send-path+verifier issue(s) still need to be filed — this document
surfaces the gap, filing them is a PM decision.

### 2.3 Figma parity (#104) vs. the UX canonical source

**Confirmed: #104's stated reference target is stale and needs updating
before its inventory work can be trusted.**

#104's own body treats Figma as the top non-decision-record authority — it
frames every diff as one of 3 buckets (intentional deviation / implementation
gap / stale Figma) with no fourth bucket for "Figma itself is stale relative
to the UX canonical source." That framing predates the 2026-08-08 decision
*"UX 正本(Notion プレスリリース)を正本階層に組み込む"*, which inserted the UX
canonical source **above** Figma: *"優先順位: 意思決定記録 > UX 正本 >
Figma > 現行コード"*. The same 2026-08-08 decision's follow-up entry
(*"着手順は「issue の統廃合確定 → gh#104 棚卸し」とする"*) explicitly lists
*"#104 の参照先(Figma か UX 正本か)"* as one of the three things this very
consolidation exercise is supposed to settle — confirming the PM already
suspected this and wanted it verified, which this section does.

Concretely, several of #104's own "未実装であることが分かっている領域" (known
gaps) now have UX-canonical-grounded specs that go further than Figma ever
did: the history-drilldown IA gap maps onto #82/#142/#143/#137, the
connect+binding interstitial gap maps onto #79, and #104's whole "会場端末"
adjacent territory maps onto #138 (which is itself in conflict with a
decision — §3.1 below). Running #104's inventory against Figma alone, as
currently scoped, would misclassify UX-canonical-driven gaps that #137-#145
already itemize as either "Figma is stale" or "implementation gap," without
checking the higher-priority source those issues are already built from.

**Recommendation direction:** re-scope #104 to check the UX canonical source
first, Figma second (matching the current hierarchy), and to explicitly
cross-reference #137-#145 so its "棚卸し" (inventory) doesn't re-derive
gaps those issues have already itemized at the feature level — #104 should
narrow to the *visual/layout* parity pass for screens whose *behavior* is
already speced elsewhere.

### 2.4 Phase threshold — #114, #116

**No overlap — sequential dependency, not duplication. Confirmed via both
issues' own text.**

#116 is the mechanical/infra step: extract the *current, unchanged* iOS
phase state machine into `shared` so both OSes agree on its semantics. It
says so explicitly: *"本 issue は現行基準を共通化するところまでで、基準は変
えない"* — first-detection-fires-eventFound stays exactly as buggy as it is
today after #116 lands. #114 is the substantive protocol fix (real N-device
consensus threshold) that both issues agree must be sequenced *strictly
after* #116: #114 says *"ScanPhase ファミリーの shared 化(#106 側)"* comes
first, then threshold ruling, then shared implementation "→両OSが同時に新
挙動を得る"; #117 (Android parity umbrella) independently confirms this
boundary by explicitly excluding #114 from its own scope: *"eventFound の判
定基準そのもの(#114...)は、Android 先行で直さない"*.

One adjacent-but-distinct note worth flagging so implementers don't conflate
the two threshold concepts: #139's "実勢表示" (relay-count majority display,
used by #141's candidate-event selection) and #114's N-device consensus
threshold (used to transition a single already-chosen event from
`.eventFound` to `.recording`) both involve "how many devices agree," but
answer different questions — which broadcast event is real, vs. when a
chosen event's mutual-sensing count is enough to start recording. Different
mechanisms, no code or spec overlap found.

### 2.5 History/summary surfaces — #82, #142, #143, #137

**Confirmed as 4 distinct, complementary surfaces — minimal literal overlap
— but with a shared, unstated downstream dependency worth flagging.**

- **#82** — per-proof drilldown detail screens (01b-05, Token ID) —
  remains blocked on a *different* precondition than the other three: census
  expansion / Contributor Proof, per DECISIONS 2026-07-30 D2 (quoted in full
  in §3.2 below). Not touched by #141/#137/#142/#143.
- **#142** — live, in-progress tally shown *during* recording.
- **#143** — post-session daily summary, explicitly self-disambiguated from
  #82/#50 in its own text: *"既存の履歴系 issue(#50/#82)はドリルダウン IA が
  主題で、この「日次サマリー + 時間帯の積み上がり」ビューは未カバー"*.
- **#137** — cross-cutting participation-state/trust view (acted / recorded
  / verified), orthogonal to the tally-focused #142/#143: it's about
  provenance state, not counts.

None of the four is a duplicate of another. What they share is an unstated
sequencing dependency: #142, #143, and #137 all explicitly say their
numbers must come from `shared`'s aggregation output, not UI-side
computation (*"数値は shared の導出値を表示するだけ"*, *"表示値はすべて
shared 台帳・receipt 由来"*) — meaning none of the three can actually be
implemented correctly before the relevant `shared` aggregation family (at
minimum #109, itself flagged with a conflict in §3.2) lands. #137
additionally needs report-server receipt semantics that don't exist yet
(it degrades gracefully to "sent so far" in the meantime, per its own text).
This is a scheduling note, not a content duplication.

### 2.6 Additional clusters found

- **Android test infrastructure — #38, #112, #118.** #112 ("Android app
  module has zero unit tests, `testDebugUnitTest` is vacuous NO-SOURCE") and
  #118 ("give Android a ViewModel layer + working Compose test setup, and
  confirm the unit-test task actually executes") substantially overlap:
  #118's own acceptance criteria include *"テストタスクが NO-SOURCE ではなく、
  実際にテストを実行している"* — the exact same assertion #112 is filed to
  fix. #38 is distinct from both: it's a physical 2-device instrumented BLE
  hardware lab (device-lab/emi), not the Gradle unit-test source set — no
  overlap with #112/#118, just adjacent Android-testing terrain worth
  tracking together when sequencing Android work.
- **Persistence hardening — #77, #131, #133, #134, #135, #136.** Not a
  duplicate cluster (different files, different failure modes: #77 is
  DeviceSecret key storage; #131/#133/#134/#136 are the unsent-window
  ledger; #135 is Proof/BindingRecord/SelfProof stores), but all six sit on
  the same persistence layer and #135 already explicitly asks to reuse
  #131's observability work and the ledger's own quarantine pattern (*"適用
  範囲の統一"*). Worth a single coordinated persistence-hardening pass
  rather than six independent PRs touching adjacent storage code, but this
  is a sequencing/PR-batching note, not an overlap requiring closure.
- **#79 vs #104 vs #138** — checked for overlap and found none beyond what
  #104 already states correctly: #104's own "未実装" list already
  cross-references #79 (*"connect+binding interstitial...#79 でデザイン
  sign-off待ち"*) with the correct relationship. No new finding here beyond
  §2.3's broader point about #104's reference target.

---

## 3. Conflicts with the decision record

This is the section the PM asked to act on first. Each entry names the
issue, quotes the specific DECISIONS entry (date + title) it contradicts,
and states the nature of the conflict. **None of these are resolved here —
flagged only, per instructions.**

### 3.1 #138 (organizer venue-device broadcast UI) vs. DECISIONS 2026-08-06 "gh#100 の §9 二論点を確定"

**Confirmed — this is the conflict the PM already suspected, and it checks
out precisely against both the decision record and the underlying approved
spec.**

DECISIONS 2026-08-06 states in full:

> 決定内容: (9.a) B005 の送信側はエンドユーザー向けには出荷せず、DEBUG 限定
> の dogfood トグルのみ用意する。受信側をテスト可能にするための最小限に留め
> る。(9.b) 主催者が付けるイベント名・会場のメタデータ機能は作らない。venue
> は当面 nil のまま
>
> 理由: (9.a) 誰でも押せる自己申告トグルにすると「beid がこの broadcast を保
> 証する」という新たな信頼の主張が生まれる。...(9.b) それは実質「イベント作
> 成機能」であり、本 issue の衣を着た別物。なお B005 の TLV は
> eventDisplayName と eventCodeHash の2種のみで、venue を運ぶ手段が構造的に
> 存在しない

`docs/specs/event-discovery.md` §9.a/§9.b (the spec this decision approved)
spells out the same ruling with explicit "RESOLVED" markers: §9.a resolved
option (a) — *"Ship nothing user-facing this slice... a `DEBUG`-only launch
argument... zero organizer UI, zero role system"* — and explicitly rejects
option (b) *"Ship a minimal self-serve toggle: any device can serve"* as
the very thing that would assert a trust claim beid doesn't back. §9.b
resolved option (b) — *"Do not build it now; venue stays absent... no
organizer-metadata feature."*

**#138 asks for exactly what both rulings reject.** Its requirements: a
"venue device mode" screen letting a designated device start/stop
broadcasting event info, with a **required label and validity period**, and
visible reassignment history. This is not a DEBUG dogfood toggle — it's a
full production toggle UI with input validation and an audit trail
(9.a conflict), and "label" + "validity period" are organizer-authored
event/venue metadata delivered via the same broadcast the decision record
says has no structural channel for it (9.b conflict). #138's own text places
the *protocol* signing side in a different repo (`levarac/barnard#122`/
`#123`, outside this consolidation's scope), but the *beid app UI* it asks
for is squarely what 2026-08-06 already ruled against for this product.

### 3.2 #109 (KMP derived-value aggregation) vs. DECISIONS 2026-07-30 "D1 owner key 確定 + D2 census 拡張は先送り"

**Confirmed — a new-wave issue proposes building something the decision
record explicitly deferred, with no override recorded since.**

DECISIONS 2026-07-30 states in full (D2 portion):

> (D2) census 拡張(= Contributor Proof 構想)は将来的な構想として今回スコープ
> 外(先送り)。依存する履歴ドリルダウン IA(01b/02/03/04/05 Proof Detail+空状
> 態)と Token ID も同様に先送り
>
> 理由: ...census は構想段階で現行の縦スライスには不要

This deferral is still in force in the repo's own committed specs — the
already-approved `docs/specs/scan-slice2-redesign.md` lists, verbatim, under
its "OUT (unchanged this slice)" section: *"Census/Contributor Proof, Token
ID field, history drill-down IA (01b/02/03/04/05 Proof Detail + empty
states) — deferred with D2."*

**#109's own scope line asks to build shared aggregation for exactly this:**
*"相互確認数、window / time-band rollup、**Contributor Proof 数値**、
venue-device（anchor）edge 抽出を shared の pure function にします."* Two
items in that list intersect the 2026-08-06/D2 rulings:

1. **"Contributor Proof 数値"** — the same term D2 explicitly deferred as
   "将来的な構想...今回スコープ外." #109 proposes formalizing it into
   `shared` as a production aggregation output, which is a step beyond
   "deferred as a future concept."
2. **"venue-device（anchor）edge 抽出"** — a term that only makes sense if
   the app has a notion of a designated "venue device" whose graph edges get
   extracted specially, which is the same organizer/venue-device concept
   §3.1's #138 conflict covers. (This is *not* the same "anchor" as the
   protocol model's on-chain batch-anchor EOA, confirmed by checking
   `docs/specs/scan-protocol-model.md`'s key roster — that's a different,
   unrelated "anchor.") This scope line assumes a venue-device concept the
   2026-08-06 ruling declined to build a UI for.

This appears in `docs/kmp-shared-foundation.md` and
`docs/kmp-shared-foundation-issue-drafts.md` as well (both added by PR #105,
2026-08-06, alongside umbrella #106) — it is not an isolated wording slip in
one issue, it is repeated across the umbrella's own planning docs. Grepping
the codebase (`ios/`, `android/`, `shared/`) for "Contributor Proof" /
"ContributorProof" returns zero implementation hits — this is scoped-but-
unbuilt, not already-shipped-and-being-converged (which would have made it
KMP-001-style SWAP work, not new scope).

### 3.3 #53 (item 1: wallet-connect-first launch flow) vs. DECISIONS 2026-07-26 "オンボーディング/接続フローをイベント先行へ変更"

**Confirmed, but a different kind of conflict than 3.1/3.2 — a
pre-existing (not new-wave) issue whose text was overtaken by a decision
recorded 3 days after it was filed, never updated since.**

DECISIONS 2026-07-26 states:

> 決定内容: 起動 → Bluetooth 許可 → イベント検知(またはイベントコード入力)で
> イベント確定 → その後に wallet connect + binding 署名を1往復で行う。
> **Welcome での事前 wallet connect は行わない。**

#53 (filed 2026-07-23, quoting that same day's MTG) still reads, as its
target-flow item 1: *"起動: 未接続なら wallet connect を要求(Coinbase /
イベントコード fallback は現行どおり)。接続済み・guest 確定済みなら何も挟
まない."* That is precisely the pre-emptive-Welcome-wallet-connect flow the
07-26 decision named and overwrote ("旧「決定3」を上書き"). #53 was never
edited after the decision landed, so its literal text still asks for the
superseded flow. Its other items (auto-start, remove Welcome, transparency
view) are unaffected and remain valid asks, already covered by §2.1's
overlap findings.

### 3.4 Citation-integrity note (not a ruling conflict) — #139's "2026-08-06 設計決定"

#139 grounds its 3-layer anti-mischief design (time-window filter, majority
display, self-heal) in a citation: *"([プレスリリース]...ギャップ表 E9、
2026-08-06 設計決定)"*. No DECISIONS.md entry dated 2026-08-06 (or any other
date) matches this specific 3-layer design, and the closest related, actually
-approved spec section — `docs/specs/event-discovery.md` §5 ("Trust model for
unauthenticated hints") — covers hint labeling/dedup/name-conflict display,
but does **not** contain a time-window filter or a relay-count majority
display. This may simply be an MTG decision not yet transcribed into
DECISIONS.md (the project has precedent for that gap, e.g. DECISIONS
2026-07-27 "プロトコルモデル資料は後追い共有"), so this is flagged as a
documentation-trail gap for the PM to close, not asserted as a substantive
conflict.

---

## 4. Recommended disposition

Recommendations only — every one names the specific issues it would act on.

| Cluster | Recommendation | Reasoning |
|---|---|---|
| §2.1 Participation surface (#100, #101, #53, #139, #141) | Fold #101 into #141 as "resolved by #141 shipping" (or, if the PM wants the narrow bug fixed sooner independent of the redesign, keep #101 open with a stated boundary: "temporary fix only, superseded once #141 ships"). Keep #100 open, re-scoped to just its still-open questions (organizer role, sequencing) since #141/#139 now answer the rest. Strike or close #53's item 1 (wallet-first flow) as superseded by the 07-26 decision; fold its transparency-view scope (item 5) into #137 and close #53 once #141/#137 are confirmed to cover the remaining live asks. | #141 is the concrete, UX-canonical-grounded design; carrying four overlapping tickets forward risks contributors building against the stale #53/#100 text instead of #141. |
| §2.2 Report pipeline (#60, #144) | Re-scope #60 down to its one still-unshipped piece (send-trigger wiring against the already-built ledger), or close it crediting its shipped scope to #91/#108/#109/#131-136. Keep #144 open as the authoritative acceptance contract. File the send-path + verifier work as new issue(s) once #144's stage-owner table is drafted (this document does not file them). | #60's body is explicitly marked stale by its own pinned comments; most of what it originally asked for already shipped under different issues. #144 is the only document that would actually close the "未起票" gap DECISIONS 2026-08-06 flagged. |
| §2.3 #104 vs. UX canonical source | Re-scope #104's reference target to "UX canonical source first, Figma second" per the current hierarchy, and have it explicitly cross-reference #137-#145 before starting its inventory pass, so it narrows to visual/layout parity rather than re-deriving behavior gaps those issues already own. | Running #104 as originally scoped (Figma-only) would misclassify UX-canonical-driven gaps and duplicate work #137-#145 already itemize. |
| §2.4 Phase threshold (#114, #116) | Keep both open, sequenced (#116 before #114), no merge/close needed. | Confirmed no overlap — this is a dependency chain, not duplication. |
| §2.5 History/summary surfaces (#82, #142, #143, #137) | Keep all four open as distinct deliverables. Note #142/#143/#137's shared dependency on #109's aggregation family landing (which itself needs the §3.2 conflict resolved first) when sequencing — don't start UI work on these three ahead of that. | Confirmed no literal duplication; the risk here is scheduling, not scope overlap. |
| §2.6 Android test infra (#38, #112, #118) | Fold #112 into #118 as a duplicate/narrower subset of #118's acceptance criteria (or keep #112 open only if the PM wants "add one real test" landed as a fast, cheap step ahead of the larger #118 architecture slice, with that boundary stated explicitly). Keep #38 open, unrelated. | #118's acceptance criteria already literally restate #112's ask; carrying both invites duplicate work. |
| §2.6 Persistence hardening (#77, #131, #133-136) | Keep all six open (different files/failure modes — not duplicates), but recommend the PM sequence them as one coordinated pass rather than independent PRs, since #135 already asks to reuse #131's observability work and the ledger's quarantine pattern. | Avoids inconsistent hardening being applied file-by-file to what is functionally one storage layer. |
| §3.1 #138 vs. 2026-08-06 gh#100 §9 | Flagged only, per instructions — not resolved here. | Real, well-grounded conflict; needs a PM/user ruling: either #138 is closed/re-scoped down to the already-approved DEBUG dogfood toggle (§6 of event-discovery.md already covers that), or the 2026-08-06 ruling is explicitly revisited and overwritten in DECISIONS.md (never silently). |
| §3.2 #109 vs. 2026-07-30 D2 | Flagged only, per instructions — not resolved here. | Needs a ruling: either #109 drops "Contributor Proof 数値" and "venue-device (anchor) edge 抽出" from its shared-aggregation scope list (and the two planning docs that repeat it), or D2's deferral is explicitly revisited and overwritten in DECISIONS.md. |
| §3.3 #53 vs. 2026-07-26 event-first decision | Recommend closing #53's stale item 1 language (see §2.1 disposition above) rather than a standalone ruling — this one doesn't need a fresh decision, just a text correction, since 07-26 already settled it. | The 07-26 decision already resolved this; #53 just never caught up. |
| §3.4 #139 citation gap | Recommend the PM either point to the actual MTG source so it can be transcribed into DECISIONS.md, or confirm it was a drafting shorthand and strike the specific date citation from #139's text. | Documentation-trail hygiene, not a scope question. |

---

## Concerns

- **Issue count**: 66 open issues found, not the 64 stated in the task. All
  66 are inventoried; the extra 2 do not change any structural finding
  above. Worth reconciling on the PM's side in case the earlier count of 64
  reflected a filter (e.g., excluding certain labels) that this session's
  plain `--state open` query didn't apply.
- **#147 numbering note**: the task described the ux-audit strand as
  "#137-#147," but #147's content (Release-build signing latency
  measurement) has no connection to the UX canonical source — it's a direct
  child of the #128/#149/#150 CI-cost/test-quality cluster, filed the same
  day by coincidence of timing, not membership. Tagged `ci` in the
  inventory, not `ux-audit`, accordingly.
- Everything else: none.
