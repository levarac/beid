# Issue #100 — organizer-role authorization options

**Status:** decision proposal, not an implementation specification
**Scope:** the one organizer-role question still open in [issue #100](https://github.com/thegreeting/beid/issues/100)

**Correction (2026-08-31, Fable-audited against primary sources):** the original
Option 3 below targeted the wrong on-chain primitive and priced it as a
from-scratch design. `registrar`/`operator` are chain-write roles only (append
event-definition anchors / commitment anchors — see
`parallax/protocol/spec/v0.1/ethereum.md`). The actual designed "who speaks for
this event" primitive is the **authority key set** (`EventKeySetV1`), a
threshold-1 set of secp256k1 keys whose digest is baked into the eventId at
registration (`parallax/protocol/spec/v0.1/event-definition.md`). Most of the
plumbing to read and verify it already exists in beid (fetch, on-chain digest
check, CBOR decode, secp256k1 verify, and the device already holds a
compatible owner key). A demo-appropriate version of this gate — a local check
that the venue device's own key is in the event's key set — is on the order of
days, not a separate production feature. The corrected Option 3 below reflects
this; **the demo recommendation is unchanged (Option 1 for 9/1)**, only the
production-path cost and primitive are corrected.

## What is already settled

The issue's original questions should not be reopened here:

- **Sender-side UI:** shipped as issue #138 in PR #187 (`VenueDeviceOrganizerView`).
- **Hint trust display:** shipped with #138/PR #187; the organizer screen says that beid does not verify the broadcast, and the receiving design treats B005 as an unauthenticated hint. **【superseded 2026-09-10】この項の後半「the receiving design treats B005 as an unauthenticated hint」は現在偽。barnard 0.8.0 の v2 署名封筒と受信 3 状態が入っている。本文書末尾の「その後（2026-09-10）」節を参照。**
- **Code distribution:** effectively resolved by the decision to adopt B005 discovery; this document does not propose a second distribution mechanism.
- **Receiver-side implementation order:** belongs to issue #141, not issue #100.

The remaining issue #100 decision is narrower: **who may turn on organizer/venue-device broadcasting for an event?**

## Current facts and threat boundary

The shipped iOS route is Account → Venue Device. The view passes only
`SensingCoordinator.joinedEventCode` into `toggleOn`; the view model checks that
an event was joined, that the label is valid, and that the validity dates are
ordered. It performs no authentication, role, permission, administrator,
registrar, or ownership check. The Barnard adapter then sets
`organizerDesignated: true` itself. Consequently, any device that knows and has
joined an event code can use beid's UI to claim organizer mode for that event.
The assignment history is local and unsigned, so it is not authorization
evidence.

This gate could reduce misuse through the official beid UI, but it cannot make
B005 trustworthy on the air. B005 hints remain unauthenticated, and a determined
nearby attacker can use another client or the Barnard SDK to broadcast a false
hint. Receiver-side trust treatment must therefore remain in place under every
option below.

**【superseded 2026-09-10】直前の段落のうち「it cannot make B005 trustworthy on the air」「B005 hints remain unauthenticated」は、B005 全体の記述としては現在偽。v2 署名封筒の経路には `RADIO_SELF_VERIFIED` / `REGISTRY_VERIFIED` という検証状態がある。ただし v1 の `eventInfoHint` だけの候補が `UNVERIFIED` に留まる点と、最後の文（受信側の trust 扱いを維持すること）は現在も正しい。本文書末尾の「その後（2026-09-10）」節を参照。**

The repository does contain a read path for EventRegistry facts. A resolved
registration exposes `registrarHex` and `operatorHex`, plus the event's key-set
and definition anchors. However, the apps currently provide a **reader**, not an
event-creation/registration transaction flow, and the organizer screen has no
wallet-address challenge or proof that the current device controls either
registry address. “Check EventRegistry” is therefore not a small conditional;
it requires an identity-proof and provisioning design as well.

## Option 1 — keep organizer mode open/self-service

Any device that has joined an event may enable venue-device mode, as today. Make
this an explicit policy rather than implying that the missing check is security.
Keep the existing warning and low-visibility placement.

- **Who can grief:** any attendee who learns the event code can use the official
  app to rebroadcast the event with a misleading label. Anyone able to run a
  custom Barnard client could do this regardless of the app gate.
- **Legitimate-organizer friction:** none beyond joining the event and entering
  the label and validity period. A replacement venue phone can be activated
  immediately without accounts, wallets, or coordination.
- **Cost before the demo:** no product-code work. The only immediate work is to
  record that open access is intentional and ensure demo operators understand
  that it is not proof of authority.
- **Tradeoff:** best demo reliability and lowest schedule risk, but beid itself
  offers the easiest path for casual (not merely determined) impersonation. The
  warning describes the trust limit but does not prevent disruption.

## Option 2 — gate with a manually shared organizer secret

Give each event an organizer PIN or high-entropy secret through a channel
separate from the attendee event code. A venue device must enter it before the
broadcast toggle is enabled.

A short PIN is only a deterrent unless attempts are rate-limited; a scannable or
pasteable high-entropy secret is materially stronger but adds provisioning and
recovery work. Storing a verifier rather than the plaintext secret avoids one
local disclosure path, but a real design still has to define who creates it,
where the verifier is authoritative, how replacement devices receive it, and
how rotation/revocation works.

- **Who can grief:** an attendee with only the event code cannot use the beid UI
  to claim organizer mode. Anyone who obtains or is forwarded the organizer
  secret can; a custom Barnard broadcaster remains possible.
- **Legitimate-organizer friction:** every venue phone needs a second credential.
  Forgotten, mistyped, expired, or unavailable secrets can block setup at the
  venue. Sharing the same secret makes replacement easy but weakens attribution
  and revocation.
- **Cost before the demo:** medium and easy to underestimate. A demo-only local
  hardcoded PIN would not authorize an event and must not be presented as this
  option. A credible version needs provisioning, secure storage, validation,
  failure UX, tests, and an operator runbook, on both platforms once an Android
  organizer surface exists.
- **Tradeoff:** blocks casual misuse without requiring a wallet, but creates a
  new credential lifecycle that is not backed by EventRegistry and may become
  throwaway work.

## Option 3 — require proof of EventRegistry authority key-set membership (corrected)

Permit organizer mode only after the device proves its own key is a member of
the event's **authority key set** (`EventKeySetV1`), the primitive
`EventRegistry` actually designed for this ("who speaks for this event"),
digest-committed into the eventId at registration and already fetched,
digest-verified, and CBOR-decoded by existing shared code
(`EventDefinitionFetcher.kt`, `EventDefinitionCborCodec.kt`). This replaces the
original draft's target of the `registrar`/`operator` addresses, which are
chain-write roles for definition/commitment anchors, not an event-speaking
role — the wrong primitive.

Two shapes, different cost:

- **(a) Local membership gate (demo-appropriate).** The device's own owner
  public key (already generated on-device, `OwnerKeyProvider.swift`) must
  appear in the resolved event's `authorityKeys` list. No network round trip,
  no signed challenge, no expiry/revocation. Needs: expose the decoded key list
  (or a membership predicate) alongside the resolved definition — additive to
  code that already runs; make the venue-toggle check async against that
  resolution (the toggle is currently synchronous,
  `VenueDeviceOrganizerViewModel.swift`); UI to show/copy the device's owner
  public key for provisioning; and registering the demo event with the venue
  device's key included in its key set (parallax-side, not app code — a
  Sepolia-registered event already exists as a template,
  `SepoliaEventRegistryIntegrationTest.kt`). **Order of days, not a separate
  production feature.** Explicitly excluded from this shape: signed challenge,
  replay/expiry, revocation, a delegation artifact, Android surface.
  **Caveat:** an authority key can rotate the event's receipt key and
  submission endpoint — putting a venue device's key in the set makes that
  device a full event authority, not a scoped delegate. Fine for a demo run by
  a single trusted operator; wrong as the general pattern.
- **(b) Remote proof (production).** A wallet- or key-signed challenge proving
  control of a specific authority key, without needing that key resident on
  the device. This is closer to the original draft's cost estimate (signed
  format, replay/expiry, wallet UX) and is contingent on a signature-to-pubkey
  recovery path that was not confirmed to exist yet (Barnard's signing surface
  exposes `verify`, not confirmed `recover`).

- **Who can grief:** an ordinary attendee cannot claim organizer mode through
  beid. A holder of an authority key (or, for shape (b), a valid delegated
  proof) can. Custom clients can still emit unauthenticated B005 regardless, so
  receivers still must not treat a hint as registry-authenticated.
- **Legitimate-organizer friction:** shape (a) needs the venue device's key
  included at event registration time (a provisioning step, not a day-of
  ceremony); shape (b) needs a signing flow per activation.
- **Cost before the demo:** shape (a) is realistically scoped to days once
  prioritized — most of the read/verify path already exists — but was not
  built by 9/1, so it does not change tomorrow's recommendation. Shape (b)
  remains high-cost and is the production target.
- **Tradeoff:** shape (a) is a cheap, real authorization check tied to a
  primitive the protocol already designed for this, at the cost of over-broad
  authority per device unless a scoped venue-role artifact is added later
  (`ethereum.md` notes roles belong in signed off-chain artifacts — that
  artifact does not exist yet and is the actual remaining production design
  work, not the key-set check itself).

## Recommendation

**For the imminent demo, choose Option 1 explicitly and time-box it.** It is the
only option with essentially zero implementation and operational risk before the
demo. The threat model must be stated accurately: this accepts casual griefing
through beid's own UI and does not make the broadcast authoritative. It must not
be described as “authorized because the device joined”; possession of the
attendee event code is not organizer proof.

**For production authorization, target Option 3 shape (a) as a near-term
follow-up, not a distant one.** EventRegistry already designed the authority
key set for exactly this role, and most of the read/verify path is already
built — a scoped venue-role delegation artifact (shape (b) or better) remains
the real longer-term work. It should be scoped in a follow-up issue and must
not block receiver-side #141 work. Option 2 is justified only if a gate is
needed before the key-set check lands and the team is willing to own secret
distribution and recovery.

### Ken's decision

Evidence can establish the implementation cost and who each option excludes;
it cannot select the acceptable business risk. Ken must explicitly decide:

1. whether the demo may ship with open organizer mode and the known casual-
   impersonation risk;
2. whether open mode is demo-only (with a removal/authorization follow-up) or an
   intentional product policy; and
3. whether the near-term follow-up should be Option 3 shape (a) (local
   authority-key-set membership check, days of work, over-broad per-device
   authority) and, if so, who owns provisioning the venue device's key into
   the event's key set at registration time.

Until that call is recorded, the accurate current-state label is **open
self-service organizer mode**, not “organizer-authorized mode.”

## その後（2026-09-10）

本節は追記であり、上の判断を書き換えるものではない。当時の記述は当時の設計を正しく写しており、
決定文書として履歴に残す。ここでは「その後に何が変わったか」だけを述べる。

### 何が superseded になったか

`:27` と、`:45`–`:49` の段落（とりわけ `:46`）は、**受信側に B005 を認証する経路が存在しない**
という前提で書かれている。barnard 0.8.0 の v2 署名封筒が入った時点で、この前提は成り立たない。

beid は両 OS で barnard 0.8.0 を pin している（`android/app/build.gradle.kts:99`、
`ios/project.yml:10`）。受信 3 状態は `shared/` の
`org.levarac.parallax.discovery.NearbyEventDiscovery` が持つ単一の判断として実装され、
iOS の `SensingCoordinator.swift` と Android の `EventJoinCoordinator.kt` /
`NearbyEventDiscoverySession.kt` から呼ばれている。

### 現在の受信設計（正本は barnard spec 122 / 134 と DESIGN-NOTES §0.2d）

ここに設計を再記述しない。決定文書が spec を再導出すれば、2 度目の陳腐化を招くだけである。
参照だけを置く。

- 受信側は検証状態を `UNVERIFIED` / `RADIO_SELF_VERIFIED` / `REGISTRY_VERIFIED` の 3 つとして
  **明示的に公開しなければならない**（spec 122「Receiver policy — the display and relay gate」。
  2026-09-05 に maintainer が批准した normative 節）。
- `RADIO_SELF_VERIFIED` は署名検証と `eventId` の自己整合までを意味し、**登録は確認されていない**。
  この状態を "verified" / "registered" としてユーザーに提示してはならない。
- 候補表示は `RADIO_SELF_VERIFIED` で進めてよい。relay・join・イベント鍵生成・observation の
  記録は `REGISTRY_VERIFIED` を下回って進めてはならない（spec 122 同節、および spec 134 の
  2026-09-05 erratum「display only」）。
- **上の gate は、join への到達路をすべて言い尽くしてはいない。** `RegistryVerifiedJoinContext` には
  factory が **2 つ**ある。typed-code 経路の `fromOperatorLookup` は、**beid の maintainer decision により
  v1.0 で維持されている**。これは候補を `REGISTRY_VERIFIED` という状態へ昇格させる経路ではなく、
  operator 経由で得た registry の答えを evidence として同じ capability 型へ到達する別経路であり、
  **relay gate は意図的に満たさない**。出典は barnard の spec ではなく **beid の code** である
  （`shared/src/commonMain/kotlin/org/levarac/parallax/discovery/RegistryVerifiedJoinContext.kt` の
  `fromOperatorLookup` 自身の doc comment: 「Kept for v1.0 by maintainer decision: code-entry join
  depends on it … it deliberately does not satisfy the relay gate」）。これは barnard の規範ではなく
  beid 側の判断であり、出典は spec ではなく code の側にある。
  どちらの factory がどの OS に配線されているかは、**本文書には書かない**。それは code の現況であって
  決定ではなく、ここに書き留めれば `:27` や `:46` とまったく同じ形で陳腐化するからである。
  共有コード上の経路は `shared/src/commonMain/kotlin/org/levarac/parallax/discovery/RegistryVerifiedJoinContext.kt` の 2 つの factory を参照し、emitter の判断は [issue #432](https://github.com/thegreeting/beid/issues/432) を参照すること。
- `REGISTRY_VERIFIED` を割り当てるのは **host だけ**である。SDK は決して割り当てない
  （DESIGN-NOTES §0.2d「The host signs, the engine serves. … The SDK holds no authority key and
  has no registry access, so it cannot sign and must not appear to: it does not re-encode,
  does not re-sign, and never assigns `REGISTRY_VERIFIED`」）。

### 当時の記述のうち、いまも正しい部分

superseded は段落全体ではない。以下は現在も成り立つので、まとめて読み替えないこと。

- **v1 の `eventInfoHint` だけから組み立てられた候補は、いつまでも `UNVERIFIED` のままである。**
  これを引き上げる手段は存在しない。つまり「B005 の hint は未認証である」は、**v1 の経路に限れば
  現在も真**であり、偽になったのは「受信側の設計には認証経路が無い」というより広い含意の方である。
- **署名は「そのイベントが登録されている」ことを証明しない。** 攻撃者は自己整合な未登録イベントを
  自由に作れる（spec 122 の rationale）。offline 検証が買うのは早い *候補表示* であって、早い
  *信頼判断* ではない。Option 3 の「Who can grief」項（`:150`–`:151`）の
  「receivers still must not treat a hint as registry-authenticated」は、この理由により現在も正しい。
- 表示名は on-chain の定義とは照合されない。`EventDefinitionV1` に表示名の欄が無く、表示名を
  認証するのは authority の署名の方だからである（spec 134 の 2026-09-05 erratum「display name」）。

### 誰が hop-0 の v2 封筒を emit するかは、本文書では決めない

現時点で beid はどの OS でも hop-0 の v2 封筒を emit していない。したがって実際に電波へ出ているのは
v1 hint が常態であり、上の「v1 の候補は `UNVERIFIED` のまま」がそのまま効いている。当時の記述が
現場の観測と一致して見えるのはこのためだが、一致しているのは観測であって設計ではない。

**誰が hop-0 の v2 封筒を emit するかは
[#432](https://github.com/thegreeting/beid/issues/432) で審議中であり、本文書では決めない。**
決定文書は確定した答えを置く場所であり、未確定の答えをここに書くことが #440 で是正された誤りそのもの
である。

**期限付き注記: #432 が閉じたら、本節のこの段落を判断結果で更新すること。**

### 追記（2026-09-10）: barnard の pin が 0.9.0 へ移った

本文書が barnard **0.8.0** を指している箇所（`:27`、`:209`、`:211`）は、**記述当時の状態としてそのまま
残す**。決定記録は履歴であって現在値ではないため、遡って書き換えない。

現在の pin は **0.9.0**（`android/app/build.gradle.kts`、`ios/project.yml`、生成される
`ios/Beid.xcodeproj/project.pbxproj`、`Package.resolved` の 4 参照すべて）。0.9.0 で本文書に関係する
変更は、spec 134 step 4 の**妥当期間の一致が「完全一致」から「包含」へ改められた**こと
（barnard#200 の 2026-09-10 erratum）である。`definitionStart <= validFromEnin` かつ
`validThroughEnin <= definitionEnd` を満たせばよい。完全一致は 12 ENIN の中継上限より長いイベント定義に
対して充足不能であり、spec 134 自身が指示する「より遅い `validFromEnin` での封筒の再発行」を
拒否してしまっていた。

上の「その後（2026-09-10）」節の判断そのものは、この erratum によって変わらない。
