# beid KMP shared foundation Issue 草案

最終更新: 2026-08-06

この文書は GitHub へ未投稿の草案です。Ken と levarac lead のレビュー前に起票しません。

既存 Issue #60（ENIN 報告パイプライン）、#91（セッション終了時の取りこぼし）、#100（B005 とイベント参加経路）、完了済み #97（hosted-Ubuntu Android CI）と重複しないよう、改訂・依存関係を明記しています。M1 UX Issue #53、#62、#50、#23 は Onodera lane のため扱いません。

---

## 草案 1: umbrella

### タイトル

KMP shared foundation を導入し、iOS / Android の共通判断を一つの runtime authority にする

### 本文

## 目的

beid の iOS と Android は現在別実装で、共通 module がありません。両 OS で同じ答えが必要な event / delegation / report ledger の判断を、project-internal な Kotlin Multiplatform module `shared/` の一つの実装へ集約します。

この Issue は実装を一つの大 PR に詰める指示ではありません。Umidori v0.10.0 の方法に従い、挙動を A / B / C に分類し、依存順の child Issue で一 family ずつ runtime authority を切り替える umbrella です。

## 方法

各 family を次に分類します。

- A / SWAP: 現行出荷挙動を oracle にして置換する
- B / CONVERGE: iOS / Android の差を先に裁定する
- C / INVENT: 新規挙動の不変条件と owner を先に決める

各行は `family / class / current iOS / current Android / ruling or invariant / owner / shared symbol / licensing test / production callers / status` を持ちます。

## 決定 KMP-001: project-internal module

`shared/` は published artifact にせず、この repository 内から source build します。これは build-evidence model の前提です。pin 済み toolchain、merge-ref の clean checkout、Android / full iOS app build により対象 source を一意にします。将来 published artifact へ変える場合は resolved-version capture と publication provenance を必須にします。

## 決定 KMP-002: Barnard は native dual implementation のまま使う

Barnard の Swift / Kotlin SDK を各 platform が直接使います。Barnard-shaped code が beid `shared/` に現れたら boundary violation です。shared が行う boundary revalidation は null / length / container shape だけとし、Barnard の署名意味、key derivation、canonical message、protocol invariant の semantic re-check を禁止します。

## 決定 KMP-003: discovered-event scoring と adoption を分ける

時間 window filter と deterministic candidate ranking は shared pure function 候補です。採用操作と presentation は Issue #100 が所有します。Issue #100 担当者が interface を ACK するまで、この family を移行台帳へ入れません。

## 初期境界

shared に置く:

- EventDefinition / DelegationCert の data model と deterministic validation
- facilitator spec に準拠する report / receipt / bundle-reference client DTO と conformance vector
- report signing payload の canonical assembly と digest 計算（native signer port は digest のみ受領）
- 相互確認数、window / time-band rollup、Contributor Proof 数値、anchor edge 抽出
- 未送信 report ledger の reducer と状態遷移
- ledger snapshot の portable codec
- platform effect の port と result の解釈

shared に置かない:

- Barnard B002-B005、BLE、ceremony、semantic re-check
- OS lifecycle / permission / secure storage / 保存場所 / atomic persistence engine
- wallet UI / callback / signing effect
- Ethereum RPC transport / key retrieval / signature execution / blob upload effect
- SwiftUI / Compose

## 受け入れ条件

- [ ] A / B / C 台帳に全 candidate family が列挙されている
- [ ] A の全行に licensing test がある
- [ ] B の全行に実装前の裁定がある
- [ ] C の全行に doc comment 化する不変条件と owner がある
- [ ] child Issue の依存順が決まっている
- [ ] `docs/kmp-shared-foundation.md` が実装と一致している
- [ ] KMP-002 の boundary check が Barnard semantic duplication を拒否する
- [ ] KMP-003 family は Issue #100 担当者の ACK 前に台帳へ入っていない
- [ ] M1 UX Issue #53 / #62 / #50 / #23 を含めていない

## Child Issue

1. walking skeleton と build wiring
2. registry decode、event / delegation model、facilitator spec 準拠の report client DTO / signing payload vector
3. 未送信 report ledger reducer と native persistence adapter
4. family ごとの platform runtime-authority 切替
5. CI と build-evidence gate

## スコープ外

- product UI の変更
- Barnard protocol の再実装
- facilitator / EventRegistry contract / blob uploader の実装
- release branch 操作

## Interface dependency

- Issue #100 が event 参加 UX、candidate adoption、B005 の利用方法を所有する。shared scoring interface は担当者の ACK が必要で、本 umbrella は UI 構造を規定しない

---

## 草案 2: walking skeleton

### タイトル

KMP `shared/` walking skeleton を Android と iOS Swift Export へ接続する

### 本文

## 目的

product rule を移す前に、KMP module boundary と両 platform の build path を作ります。古い import や stale module 参照が compile error になり、CI が必ず検出できる状態を先に完成させます。

## 実装

- root に `shared/` を追加する
- `commonMain / commonTest / androidMain / androidHostTest / iosMain / iosTest` を定義する
- Android Gradle root から `:shared` を `../shared` として include する
- Android app は `implementation(project(":shared"))` で直接参照する
- Swift Export module 名は `BeidSharedKit` とする
- `ios/project.yml` に `:shared:embedSwiftExportForXcode` の build phase を追加し、XcodeGen で project を再生成する
- 対応 JDK を明示的に選び、Xcode の ambient `JAVA_HOME` へ依存しない
- iOS / Android から同じ walking-skeleton 値を読む

## 受け入れ条件

- [ ] `:shared:testAndroidHostTest` が通る
- [ ] `:shared:iosSimulatorArm64Test` が通る
- [ ] `:app:testDebugUnitTest :app:assembleDebug` が通る
- [ ] Xcode Cloud の app build/test が fresh Swift Export を生成して通る
- [ ] generated output を削除しても Xcode build が復元する
- [ ] Swift 側の runtime type が `BeidSharedKit` 由来である
- [ ] 古い module 名 / 存在しない symbol を入れる negative fixture が compile failure になる
- [ ] `.xcodeproj` を直接編集せず、`ios/project.yml` と生成結果が一致する

## build 証拠

- exact SHA
- merge ref を clean checkout した CI run ID（SHA で filter して確認する）
- Gradle task と test 数
- JDK version
- Swift Export fresh-generation log
- published dependency を変更した場合は resolved version と取得経路
- local claim の場合は composite build / substitution が無いこと

## スコープ外

- EventDefinition、report ledger などの product rule
- GitHub-hosted macOS（iOS は Xcode Cloud）
- XCFramework を配布物として公開すること

---

## 草案 3: protocol model

### タイトル

Registry response decode、EventDefinition / DelegationCert、report signing payload を shared に定義する

### 本文

## 目的

EventRegistry を event definition の正本とし、DelegationCert を電波と bundle に同乗させ、report bundle を Ethereum blob へ公開する確定アーキテクチャを、両 OS が同じ判断で扱える shared client contract にします。

これは C / INVENT です。現行 iOS `WindowReport` の provisional payload を oracle にしません。

report envelope / bundle の canonical format は facilitator spec 側が所有します。CBOR/COSE profile、AcceptanceReceipt / InclusionReceipt、reportRoot、natural-key conflict、canonical bytes を本 Issue で再定義しません。facilitator spec の conformance vector を client 側から消費します。

## shared が所有するもの

- `EventDefinition/v1` data model と validation
- native Ethereum RPC transport が返した bytes の decode
- self-certifying `eventId` の照合規則
- `DelegationCert/v1` data model、role bitset、有効 ENIN window の validation
- facilitator spec が定める report / AcceptanceReceipt / InclusionReceipt / bundle reference の client-side DTO
- facilitator spec の protocol state を client ledger event へ写す validation と error mapping
- facilitator spec に従う to-be-signed payload の canonical assembly と digest 計算
- unknown extension / version の扱い
- decode / encode / validation error の machine-readable category

## platform / 別 repo が所有するもの

- EventRegistry の contract 実装と登録 transaction
- Ethereum RPC transport と cache
- B005 の送受信、署名、ceremony（Barnard）
- key retrieval、event signing / owner key / wallet signature の実行
- blob upload と facilitator API
- CBOR/COSE profile、receipt semantics、reportRoot、Merkle leaf、canonical byte layout の決定（facilitator spec が所有）

## vector に含める境界

- field 欠落 / null / empty
- ENIN start/end の境界と逆転
- unknown version / extension / role bit
- eventId mismatch
- DelegationCert の期限外、event mismatch、権限不足
- facilitator spec conformance vector に対する canonical field order と複数値の順序
- registry response bytes の valid / truncated / wrong-version / wrong-event vectors
- to-be-signed payload と digest の byte-exact vectors
- report が複数 window を含む場合の重複 / 欠落

## 受け入れ条件

- [ ] 不変条件と owner が production code の doc comment にある
- [ ] `commonTest` が全 vector を読む
- [ ] Android host test と iOS test が同じ vector を読む
- [ ] facilitator spec の canonical conformance vector と byte 一致する
- [ ] facilitator spec と異なる独自 canonical format / 二つ目の spec authority を作っていない
- [ ] shared payload builder が facilitator vector と同じ digest を返す
- [ ] signer port が digest だけを受け取り、native に payload assembly がない
- [ ] invalid vector が loader に無視されず明示的に失敗する
- [ ] Barnard の型・bytes・semantic invariant を複製していない（null / length / shape check のみ）
- [ ] 現行 `WindowReport.windowReportPayload` を互換性の根拠にしていない

## 依存

- umbrella の A / B / C 台帳
- facilitator spec の CBOR/COSE、receipt、reportRoot、bundle profile が実装可能な粒度で確定している
- EventRegistry / facilitator / Barnard 間の spec owner の確認

## 関連

- 既存 Issue #60 は送信・台帳側。本 Issue は payload contract の前提になる
- 既存 Issue #100 の B005 表示・参加 UI は interface dependency。受け取った event definition の検証結果だけを提供し、UI を規定しない

---

## 草案 4: 既存 Issue #60 の改訂案

### タイトル案

ENIN 単位の未送信 report ledger を shared reducer と native persistence で実装する

### 本文案

## 変更理由

Issue #60 の目的は維持しますが、2026-08-06 に EventRegistry / Ethereum blob / DelegationCert / unsent-report ledger の配置が確定しました。また KMP shared foundation を導入するため、状態遷移と保存機構の責務を分けます。

## shared が所有するもの

- window observation の open / close
- pending / in-flight / acknowledged / retryable-failed
- 一 report に含める未送信 window の選択
- acknowledgement / receipt を受けた後の遷移
- retry eligibility と idempotency key
- ENIN 境界 / 明示停止 / background が競合した時の二重 close 防止
- ledger snapshot の serialize / deserialize format

## native が所有するもの

- iOS / Android の lifecycle event の取得
- snapshot bytes の保存場所と atomic persistence の実装
- Barnard observation の受領
- key retrieval と event signing の実行（shared が渡した digest のみを署名）
- facilitator への送信と network retry の実行
- acceptance / inclusion receipt の保存 effect

## 不変条件

1. closed window は persistence 成功後にだけ送信候補になる
2. acknowledged window は再送しない
3. crash 後も pending / in-flight を失わない
4. 同じ window を二重 close しない
5. 一つの report に複数 window を含められる
6. 未送信 window だけを次の report に含める
7. snapshot codec は iOS / Android / restore 経路で同じ状態へ round-trip する
8. native signer は payload を組み立てず、shared が計算した digest だけを署名する

## 受け入れ条件

- [ ] reducer の `commonTest` が ENIN 境界 / 停止 / background の三経路を通す
- [ ] 三経路が同時に来る permutation test で二重 close がない
- [ ] kill / relaunch 相当の platform test で pending と in-flight が復元する
- [ ] shared snapshot codec の golden vector を iOS / Android が同じ bytes へ serialize し、同じ状態へ deserialize する
- [ ] iCloud sync / best-effort server restore 相当の portable snapshot round-trip が通る
- [ ] acknowledged window が再送されない
- [ ] guest でも report pipeline が完走する
- [ ] event signing key の署名を検証できる
- [ ] signer port の test double が digest 以外を受け取らず、native 側に payload assembly がない
- [ ] iOS と Android が同じ vector / reducer を使う
- [ ] native adapter に ledger 判定が残っていない
- [ ] production caller の runtime-authority gate が KMP call を外すと RED になる

## Issue #91 との二段階の関係

Phase 1（現在）: Issue #91 の native correctness fix は KMP を待たず、そのまま進めます。sub-slice 1 の PR #99 と sub-slice 2（background-transition window checkpoint）の PR #103 は着地済みです。残る native slice も、今日のデータ欠損を防ぐため先に進めます。

Phase 2（ledger cutover）: Phase 1 で確定した session-end semantics を A / SWAP oracle とし、Issue #91 の再現 case を shared reducer の licensing test / crash-safety vector にします。KMP 切替時に native fix の意味を失わず、同じ判断を二重実装として残しません。

## スコープ外

- payload schema と canonical bytes の裁定（facilitator spec が所有し、protocol-model Issue は client DTO と conformance vector を消費する）
- facilitator server / blob upload の実装
- report 履歴 UI

---

## 草案 5: runtime authority cutover

### タイトル

Derived-value aggregation と discovered-event candidate scoring を KMP authority にする

### 本文

## 目的

両 OS で同じ数値と候補順を出すため、相互確認数、window / time-band rollup、Contributor Proof 数値、venue-device（anchor）edge 抽出を shared の pure function にします。同じ computation family である将来の booth-visit derivation もここへ接続します。

発見イベントの時間 window filter と deterministic ranking も shared 候補ですが、採用操作と presentation は Issue #100 が所有します。

## 着手前 gate

- 各 aggregation の input / output と境界 vector
- iOS と Android の production caller 一覧
- Issue #100 担当者による candidate-scoring interface の ACK

Issue #100 の ACK が無ければ aggregation family だけを進め、candidate scoring は台帳へ入れません。

## 実装

- shared に aggregation API、anchor edge extraction、vector を置く
- ACK 後にだけ candidate filter / ranking API を置く
- iOS は `BeidSharedKit` への薄い adapter にする
- Android は同じ shared symbol を直接使う
- Barnard observation は native SDK から受け取り、shared 境界では null / length / shape だけを確認する

## 受け入れ条件

- [ ] 旧 iOS 実装に対して licensing test が RED になることを確認した
- [ ] shared vector を common / Android / iOS が読む
- [ ] iOS adapter は変換 + shared call + 投影だけである
- [ ] Android production caller が shared symbol を使う
- [ ] source-shape gate が native count / rollup / ranking 再実装を拒否する
- [ ] runtime value と `BeidSharedKit` authority type を確認する
- [ ] shared call を外す mutation で RED になる
- [ ] mutual count、time-band、Contributor Proof、anchor edge が両 OS で同じ vector 結果になる
- [ ] Barnard semantic invariant を shared へ複製していない
- [ ] candidate scoring を含める場合、Issue #100 担当者の ACK が記録されている

## スコープ外

- EventRegistry RPC transport
- candidate adoption / B005 UI
- report ledger
- wallet binding

---

## 草案 6: CI と evidence

### タイトル

KMP shared 変更を両 platform で検証し、resolved dependency を build 証拠に含める

### 本文

## 背景

完了済み Issue #97 で hosted-Ubuntu の Android build lane は追加されました。KMP 導入後は `shared/**` の変更が Android と iOS の両方へ影響します。

また、beid main は Maven Central と一致しない stale import を含んだまま 5 日間 compile 不能でした。その変更では local `assembleDebug passed` が報告されていましたが、実際に何へ resolve して build したかが証明されていませんでした。

## GitHub Actions

- hosted `ubuntu-latest` を使う
- `:shared:testAndroidHostTest`
- `:app:testDebugUnitTest`
- `:app:assembleDebug`
- `shared/**` と Gradle/JDK integration の変更で必ず起動する
- Kotlin plugin、Gradle wrapper checksum、JDK を repo / workflow 内で pin する
- published dependency を変更する PR は `dependencyInsight` を log に残す

## Xcode Cloud

- GitHub-hosted macOS は追加しない
- app build/test が `:shared:embedSwiftExportForXcode` を実行する
- KMP test だけへ縮めず、fresh Swift Export から full app を compile / link する
- fresh output が無い、JDK selection が失敗した、Swift Export call が外れた場合は fail する
- XcodeGen drift guard を維持する

## build claim の必須項目

- exact SHA
- clean checkout CI / local の別
- task と test 数
- clean merge-ref checkout であること。published dependency を変更した場合は resolved version と取得経路も必要
- composite build / dependency substitution / local override の有無
- fresh Swift Export の有無

## forward-port gate

release branch へ移す時は destination branch を base とする merge ref の clean checkout で全 lane を再実行します。`CI green on <exact head SHA>, run <run id>` を記録し、PR checks summary ではなく SHA-filtered run を確認します。source branch の green を流用しません。

`shared/` が project-internal module である間は、pin 済み toolchain + clean merge-ref checkout + Android / full iOS app build で十分です。将来 `shared/` を published artifact に変える場合は resolved-version capture を必須にします。Barnard のような published dependency 自体を変更する PR は、現在も clean build と resolved-version capture の両方を必要とします。

この project-internal 選択は umbrella の「決定 KMP-001」で固定します。CI を軽くするための便宜ではなく、checkout した source と build 対象を一致させる load-bearing な前提です。

## 受け入れ条件

- [ ] `shared/**` の fixture PR で Ubuntu と Xcode Cloud の両 lane が起動する
- [ ] stale Android import fixture が compile failure になる
- [ ] stale Swift Export import fixture が Xcode build failure になる
- [ ] Barnard dependency を変更する fixture では、dependency log から Maven Central の resolved version を特定できる
- [ ] local composite substitution が有効なら gate が検出または明示的に fail する
- [ ] destination branch の merge ref を別 build として扱い、exact head SHA と SHA-filtered run ID を記録する
- [ ] required check は lightweight Ubuntu。macOS build/test は Xcode Cloud のまま

## 依存

- walking-skeleton Issue
- 完了済み Issue #97 の Android lane
