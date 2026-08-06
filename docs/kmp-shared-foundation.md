# beid KMP shared foundation 作業マニュアル

最終更新: 2026-08-06

この文書は、beid に Kotlin Multiplatform の `shared/` module を導入し、iOS と Android の共通判断を一つずつ移すための手順書です。設計案を並べる文書ではありません。作業者は上から順に実施し、各 gate を満たしてから次へ進んでください。

基礎にした方法は ShiokazeHD/umidori の v0.10.0 KMP 切替です。ただし、beid は greenfield、Umidori は既存の Swift shared runtime からの切替でした。Umidori の構造と証明方法を使い、Umidori 固有の runner・一括置換・旧 runtime 削除はコピーしません。

## 1. 最初に決めること

コードを書く前に、移したい挙動を次の台帳へ一行ずつ記録します。

| class | 意味 | 実装前に必要なもの | 完了の証拠 |
| --- | --- | --- | --- |
| A / SWAP | 現在出荷している挙動を同じ意味の shared 実装へ置き換える | oracle となる既存実装と、移行前の実装では落ちる licensing test | 共通 vector、platform adapter、runtime authority gate、旧判断の不在 |
| B / CONVERGE | iOS と Android の判断が異なる | どちらを正とするかの裁定 | 裁定を表す vector と両 platform の同一結果 |
| C / INVENT | 出荷側に対応物がなく、新しい挙動を作る | 不変条件、仕様の所有者、失敗時の扱い | 不変条件をコードの doc comment と test で固定 |

台帳には最低でも次の列を持たせます。

```text
family | class | current_ios | current_android | ruling_or_invariant |
owner | shared_symbol | licensing_test | platform_callers | status
```

`licensing_test` が空の A 行は移行しません。`ruling_or_invariant` が空の B/C 行も実装しません。先にコードを書くと、実装者が暗黙に仕様を決めてしまうためです。

### beid の初期分類

| family | 初期 class | 方針 |
| --- | --- | --- |
| Barnard `EventIdHash` / ceremony 入出力 | shared 対象外 | KMP-002 により Barnard native SDK が所有する。beid shared は null / length の shape check だけを行う |
| `EventDefinition/v1` | C | EventRegistry を正本とする不変条件を先に固定する |
| `DelegationCert/v1` | C | 検証可能な data model は shared。BLE 送受信と ceremony は Barnard に残す |
| report client DTO / bundle 参照 | C | facilitator spec が定める CBOR/COSE・receipt・reportRoot を依存先とし、beid 側で canonical format を再定義しない |
| 未送信 report ledger | C | window 単位、crash 復旧、重複送信防止の状態遷移を先に固定する |
| report signing payload / digest | C | facilitator spec に従う canonical assembly と digest は shared。native signer port は digest だけを受け取る |
| derived-value aggregation | C | 相互確認数、window / time-band 集計、Contributor Proof 数値、anchor edge 抽出を shared が所有する |
| discovered-event candidate scoring | C・ACK 待ち | 時間 window filter / ranking は shared 候補。採用と表示を所有する Issue #100 担当者の ACK 後に台帳へ入れる |
| ledger snapshot codec | C | serialize / deserialize format は shared。native は保存場所と atomic write だけを所有する |
| 現行 `WindowReport` payload | 移植しない | コメント上も wire layout が未確定。既存 Swift を oracle にしない |
| wallet binding / owner-key ceremony | shared 対象外 | Barnard と native wallet adapter が所有する |

既存の GitHub Issue #60 と #91 は report ledger の要件入力です。古い payload をそのまま移す根拠にはしません。

Issue #91 の correctness fix は KMP 導入を待ちません。sub-slice 1 の PR #99 と sub-slice 2 の PR #103 は native track で着地済みです。残る native slice も先に進め、その shipped session-end semantics を後の A / SWAP oracle と licensing test に使います。

## 2. `shared/` の責務

`shared/` は「両 OS が同じ答えを出す必要がある判断」を所有します。

### 決定 KMP-001: `shared/` は project-internal module にする

`shared/` は Maven / SwiftPM へ公開せず、この repository の Android と iOS だけが source checkout から build します。この選択は配布方法だけでなく、CI の証拠モデルを支える決定です。

- toolchain を repo 内で pin する
- PR の merge ref を clean checkout する
- Android app と full iOS app を compile / link する

この三条件により、checkout した tree が `shared/` の実体を一意に決めます。将来 published artifact に変える場合は KMP-001 の変更として扱い、resolved-version capture と publication provenance を CI の必須条件へ追加します。

### 決定 KMP-002: Barnard は native dual implementation のまま使う

Barnard は当面、公開済みの Swift / Kotlin SDK を各 platform が直接使います。B002-B005、BLE、owner-key、binding、ceremony、Barnard canonical message など Barnard-shaped code が beid `shared/` に現れたら境界違反です。

beid `shared/` が Barnard 境界で確認してよいのは null、byte length、container shape だけです。Barnard が既に保証する署名意味、key derivation、message semantics、protocol invariant を再検証しません。semantic re-check は安全策ではなく、二つ目の Barnard 実装を作る重複です。

### 決定 KMP-003: 発見イベントの scoring と adoption を分ける

候補イベントの時間 window filter と deterministic ranking は、両 OS で同じ候補順を出すため shared の pure function 候補です。候補を実際に採用する操作と表示は Issue #100 が所有します。この family は Issue #100 担当者が interface を ACK するまで移行台帳へ入れません。

```text
shared/
├── build.gradle.kts
├── src/
│   ├── commonMain/kotlin/org/levarac/beid/shared/
│   │   ├── event/       registry response decode、EventDefinition、candidate scoring
│   │   ├── delegation/  DelegationCert の data model と検証
│   │   ├── report/      payload/digest、集約、ledger reducer / snapshot codec
│   │   └── ports/       platform effect の interface
│   ├── commonTest/kotlin/...
│   ├── androidMain/kotlin/...    Android 固有の engine が必要な時だけ
│   ├── androidHostTest/kotlin/...
│   ├── iosMain/kotlin/...        iOS 固有の engine が必要な時だけ
│   └── iosTest/kotlin/...
└── testdata/vectors/
```

`commonMain` に置くもの:

- native RPC が返した bytes の decode と `EventDefinition/v1` の検証
- `DelegationCert/v1` の shape、権限・有効 window の判断
- facilitator spec が定めた report / receipt / bundle の client-side DTO、検証、error mapping
- facilitator spec に従う to-be-signed payload の canonical assembly と digest 計算
- 相互確認数、window / time-band rollup、Contributor Proof 数値、venue-device（anchor）edge 抽出
- 未送信台帳 snapshot の portable serialize / deserialize format
- 未送信台帳の状態と純粋な reducer
- Issue #100 の ACK 後に限り、発見イベント候補の時間 filter と deterministic ranking
- port の interface と、effect 実行後の result を状態へ戻す規則
- platform 共通の error category / recovery action

`shared/` に置かないもの:

- Barnard の B002-B005、BLE scan/advertise、ceremony と semantic re-check
- CoreBluetooth、Android permission、background lifecycle
- Keychain、Keystore、保存場所、atomic file write、SQLite transaction などの保存機構
- WalletConnect / Coinbase / MetaMask の UI と callback
- Ethereum RPC transport、key retrieval、署名の実行、blob upload の実行
- report envelope / bundle の canonical byte layout の決定（facilitator spec が唯一の正本）
- SwiftUI / Compose の画面、navigation、platform 文言

effect は native が実行します。たとえば reducer が `PersistWindow` や `SubmitReport` を返し、native adapter が保存・送信し、その結果を `PersistSucceeded` / `SubmitFailed` として reducer へ戻します。shared から OS API を直接呼びません。

署名も同じ分離です。shared が canonical to-be-signed payload と digest を作り、signer port へ digest だけを渡します。native は key を取得して署名を実行し、signature result を shared へ戻します。native が payload layout や digest preimage を手組みしません。beid#88 のように作成側と verifier の byte layout がずれる事故を、この境界で防ぎます。

表示は native のままですが、表示する数値は shared output を使います。相互確認数、時間帯別集計、Contributor Proof、anchor edge、将来の booth-visit derivation を Swift / Kotlin で別々に計算しません。

## 3. walking skeleton を作る

最初の PR は product rule を移しません。module boundary と build path だけを作ります。

1. root に `shared/` を作る。
2. `android/settings.gradle.kts` に `:shared` を追加し、`projectDir` を `../shared` へ向ける。
3. `android/app/build.gradle.kts` から `implementation(project(":shared"))` で直接参照する。
4. `commonMain` に副作用のない walking-skeleton API を一つ置く。
5. `commonTest` と Android host test から同じ API を呼ぶ。
6. Swift Export module 名を `BeidSharedKit` とし、iOS arm64 と iOS Simulator arm64 を対象にする。
7. `ios/project.yml` に Xcode build phase を定義する。生成済み `.xcodeproj` を直接編集しない。
8. build phase は Android Gradle root から `:shared:embedSwiftExportForXcode` を実行する。
9. `cd ios && xcodegen generate` で project を再生成する。
10. Swift 側から walking-skeleton API を呼び、値と runtime type が `BeidSharedKit` 由来であることを test する。

Swift Export の生成物は derived artifact です。手で編集せず、runtime authority として commit しません。API review 用 snapshot を置く場合も、fresh generation と一致することを CI で検査し、snapshot を実行時依存にはしません。

### walking skeleton の完了条件

- Android app が `project(":shared")` を使って compile する。
- `:shared:testAndroidHostTest` が通る。
- `:shared:iosSimulatorArm64Test` が通る。
- Xcode build が build phase で Swift Export を新規生成し、iOS app と tests がそれを import する。
- generated output を消した状態からでも Xcode build が復元できる。
- 存在しない shared symbol、古い module 名、古い import を意図的に入れると CI が compile error で落ちる。

## 4. 一つの family を移す

一度に一つの判断 family を扱います。画面単位ではなく、同じ規則を答える symbol 群を一つの family とします。

### Step 1: oracle または invariant を固定する

- A: 現行の出荷挙動を vector にする。
- B: 差分を列挙し、Issue 上で裁定してから vector にする。
- C: doc comment に置く不変条件と owner を先に決め、境界ケースを vector にする。

vector は含まれるケースしか証明しません。`null`、欠落、空、最小・最大、順序違い、重複、unknown field、期限境界を明示して入れます。report の canonical bytes は facilitator spec の conformance vector を取り込み、beid 独自の二つ目の正本を作りません。

### Step 2: RED を記録する

shared 実装を呼ばない状態、または旧 native 判断の状態で licensing test が失敗することを確認します。最初から green の test は、その移行を licence しません。

### Step 3: `commonMain` へ判断を置く

data class、validator、reducer は純粋関数を優先します。shared が所有する event / delegation の canonicalizer も同様です。report canonicalization は facilitator spec の実装・vector を使い、beid 独自実装を足しません。OS 時刻、random、storage、network、signature は port から入力します。

### Step 4: native adapter を薄くする

adapter がしてよいことは次の三つです。

1. native type を shared input へ写す。
2. shared を一度呼ぶ。
3. shared output を既存 UI-facing type へ写す。

adapter に同じ validation、分岐、clamp、retry 判定を残しません。

Barnard adapter だけは例外ではなく別境界です。shape check は許可しますが、Barnard invariant の semantic re-check を shared adapter に足しません。

### Step 5: production caller を全数確認する

adapter 自身が正しくても、本番画面や coordinator が旧 helper を呼び続ければ移行は未完了です。symbol search と test で実際の caller を全数確認します。

### Step 6: 二層の ownership gate を置く

各 family に次の二層を置きます。

- source shape: adapter 全体が期待する薄い形であり、旧判断の literal・分岐・helper が存在しない。
- runtime authority: 実行値に加え、実際の型または呼び出し先が `BeidSharedKit` 由来であることを確認する。

さらに KMP call を外す、または native 判断を戻す mutation を入れると test が RED になることを一度確認します。substring 一個だけの grep は ownership proof にしません。

## 5. report ledger へ適用する

未送信台帳は data store ではなく、状態遷移を shared に置きます。

最低限の状態:

- window observation が open / closed のどちらか
- closed chunk が pending / in-flight / acknowledged / retryable-failed のどれか
- report が含む window ID の集合
- acceptance / inclusion receipt の有無
- attempt と retry eligibility

最低限の不変条件:

1. window は閉じるまで report へ入らない。
2. 閉じた window は atomic persistence が成功するまで送信候補にならない。
3. acknowledged window は再送しない。
4. crash 後の復元で pending / in-flight を失わない。in-flight の扱いは idempotency key と server contract で決める。
5. 一つの report に複数 window を含められるが、各 window の所属は一意である。
6. 明示停止、background、ENIN 境界が同時に来ても同じ window を二重 close しない。
7. Barnard が出した observation / ceremony artifact は改変せず参照し、BLE protocol を再実装しない。
8. report / AcceptanceReceipt / InclusionReceipt / reportRoot の意味と canonical encoding は facilitator spec に従い、client reducer が独自解釈を足さない。
9. ledger snapshot は shared codec で round-trip し、iOS / Android / restore 経路で同じ bytes と状態を得る。
10. report signer port は digest だけを受け取り、native 側に payload assembly を持たない。

native persistence adapter は shared codec が返した bytes を tmp file + atomic replace、database transaction など各 OS の安全な方法で保存します。保存場所と atomicity は native、snapshot format は shared です。shared test は in-memory fake を使い、platform test は kill/relaunch、iCloud sync、best-effort server restore 相当の portable round-trip を検証します。

## 6. CI lane

### GitHub-hosted Ubuntu

beid は ShiokazeHD の self-hosted-only 制約の対象ではありません。軽量な required check は `ubuntu-latest` で構いません。

`shared/**`、Android Gradle 設定、KMP integration script が変わった時は、最低でも次を走らせます。

```bash
cd android
./gradlew :shared:testAndroidHostTest \
  :app:testDebugUnitTest \
  :app:assembleDebug \
  --no-daemon --no-parallel
```

iOS native test は GitHub-hosted macOS で走らせません。

toolchain は checkout だけから再現できるよう repo 内で pin します。Kotlin plugin version、Gradle wrapper と distribution checksum、CI の JDK version を暗黙の latest にしません。

### Xcode Cloud

Xcode Cloud の app build/test 自体が `:shared:embedSwiftExportForXcode` を実行しなければなりません。生成物を事前に commit して Xcode build phase を迂回してはいけません。

Xcode Cloud で確認するもの:

- XcodeGen の drift guard が通る。
- 対応 JDK を明示的に選び、ambient `JAVA_HOME` に依存しない。
- Swift Export が空でない。
- iOS app build と tests が fresh output に対して通る。
- ownership gate が iOS production caller を含めて通る。

### path filter

`shared/**` の変更は Android と iOS の両 lane を起動します。`android/settings.gradle.kts`、Gradle wrapper/plugin version、JDK selector の変更も両 lane を起動します。module build の前提が変わるためです。

## 7. build 成功を報告する時の証拠

`assembleDebug passed` だけでは不十分です。beid では、Maven Central に存在しない古い import を含む main に対して local build 成功が報告され、Android が 5 日間 compile 不能のまま残りました。

証拠は dependency の種類で分けます。

- project-internal `:shared`: exact target head の merge ref を clean checkout した CI で、shared test、Android app、full iOS app を compile / link すればよい。外部 artifact の版解決は存在しない。
- published dependency（Barnard など）を変更する PR: 上の clean-checkout build に加え、package manager が実際に選んだ version と取得経路を記録する。
- local build: clean checkout でないなら、local composite build / substitution / Maven override の有無を別途示す。

Swift Export には lockfile がありません。証拠は fresh generation からの full iOS app compile + link です。lane を KMP 単体 test だけへ縮めると、Swift から実際に使えることを証明しなくなります。

build 報告には次を必ず含めます。

- build した exact commit SHA
- clean checkout の CI か、local checkout か
- 実行した task と test 数
- dependency を変更した場合は、その published dependency の resolved version と取得経路
- composite build / dependency substitution / local Maven override の有無
- Swift Export の fresh generation を行ったか

Barnard など published dependency を変更した claim、または clean checkout でない local Android claim を出す時は、build と同じ checkout で少なくとも次も保存します。

```bash
cd android
./gradlew :app:dependencyInsight \
  --dependency org.levarac:barnard \
  --configuration debugRuntimeClasspath
```

最終的な merge gate は clean checkout の hosted-Ubuntu CI と Xcode Cloud に置きます。PR CI は `refs/pull/<N>/merge` の merge ref を build し、実際に着地する tree を検証します。報告は `CI green on <exact head SHA>, run <run id>` の形にし、PR checks の集約表示ではなく SHA で filter した run を確認します。集約表示は古い attempt を見せる場合があるためです。

Gradle cache があっても構いませんが、source checkout、dependency graph、local substitution が曖昧な build を証拠にしません。

## 8. release branch へ forward-port する時

source branch で通った結果を destination branch の証拠として使いません。release branch では Kotlin、Gradle、Barnard、SwiftPM の resolved set が異なる場合があります。

1. destination branch の exact head を記録する。
2. その branch を base にする PR の merge ref を clean checkout する。
3. shared host tests、Android app build、full Xcode Cloud app build/test を merge ref で再実行する。
4. exact head SHA と CI run ID を記録し、SHA-filtered run が green であることを確認する。
5. published dependency を変更する場合は、destination で package manager が選んだ resolved version も記録する。
6. source と destination の resolved set が違えば、差を報告する。
7. destination で native 旧判断を復活させていないことを ownership gate で確認する。

この簡略化が成立するのは `shared/` が project-internal module の間だけです。将来 published artifact として配布するなら、clean checkout だけでは版を特定できないため、resolved-version capture を必須へ変更します。

## 9. PR checklist

- [ ] 台帳の family / class / oracle または invariant が埋まっている
- [ ] RED の falsifier を確認した
- [ ] shared vector に欠落・空・境界・unknown を含めた
- [ ] Android と iOS の production caller を全数確認した
- [ ] native adapter に判断が残っていない
- [ ] report の署名対象 payload と digest は shared が facilitator spec に従って作り、native signer は digest だけを受け取る
- [ ] 相互確認数、window / time-band 集計、Contributor Proof 数値、anchor edge は shared output であり、native は表示だけを行う
- [ ] Ethereum RPC transport は native、返却 bytes の decode / validation は shared に分かれている
- [ ] ledger snapshot codec は shared、保存場所と atomic write は native に分かれている
- [ ] Barnard-shaped code を shared に置かず、境界確認を null / length / container shape に限定して semantic re-check を重複させていない
- [ ] candidate scoring を含める場合、Issue #100 担当者の interface ACK が記録され、adoption / presentation を移していない
- [ ] OS / wallet / storage engine の責務を shared に移していない
- [ ] Android host test と app build が clean checkout で通った
- [ ] Xcode Cloud が fresh Swift Export から app/test を build した
- [ ] exact head SHA と SHA-filtered CI run ID を記録した
- [ ] published dependency を変更した場合、resolved version と取得経路を記録した
- [ ] forward-port がある場合、destination branch の graph で再検証した

## 10. 参照した一次資料

- ShiokazeHD/umidori Issue #693: v0.10.0 shared runtime 置換の受け入れ条件と A/B/C 台帳
- ShiokazeHD/umidori Issue #780: iOS family ごとの stacked runtime-authority 切替
- ShiokazeHD/umidori PR #777: `shared/` 構造、Android 直接参照、Swift Export、ownership gate
- `ShiokazeHD/umidori@release/0.10.0`: `shared/build.gradle.kts`、Android settings/app、PR CI
- `Levarac/design-notes/2026-08-06-beid-reporting-claim-architecture.md`
- Kura `journal/2026-08-06-levarac-beid-android-ci-blind-spot.md`
