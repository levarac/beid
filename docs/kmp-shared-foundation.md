# beid KMP shared foundation 作業マニュアル

> **English preface — navigation only.** This is the authoritative, ordered
> implementation manual for moving beid decisions into `shared/`; the Japanese
> body is the single source of truth. On detailed KMP procedure, it overrides
> `AGENTS.md` when they conflict (repository-wide safety and delivery rules in
> `AGENTS.md` still apply). Section map: shared/native ownership boundary §2;
> walking-skeleton completion conditions §3; build commands §6; stacked-branch
> rebase rule §8. This signpost is not a second summary of those rules.

最終更新: 2026-08-08

実装照合: `origin/main` @
`f3714c36b24952ad760d9e5a6ff927de8d2b09e1`、`shared/src/`、
`ios/Beid/Sensing/`、`ios/Beid/Persistence/`、Android の shared bridge / native store、
`ios/project.yml`、`Package.resolved`、Android Gradle graph、`.github/workflows/pr-ci.yml`。

この文書は、beid に Kotlin Multiplatform の `shared/` module を導入し、iOS と Android の共通判断を一つずつ移すための手順書です。設計案を並べる文書ではありません。作業者は上から順に実施し、各 gate を満たしてから次へ進んでください。

`AGENTS.md` の KMP section は ownership boundary と repository-wide constraints の要約であり、本書は詳細な KMP 作業手順の正本です。両者が KMP の詳細手順で食い違う場合は本書を優先し、同じ変更で `AGENTS.md` の要約も直します。`AGENTS.md` の repository-wide safety / delivery rules は引き続き適用します。

基礎にした方法は ShiokazeHD/umidori の v0.10.0 KMP 切替です。ただし、beid は greenfield、Umidori は既存の Swift shared runtime からの切替でした。Umidori の構造と証明方法を使い、Umidori 固有の runner・一括置換・旧 runtime 削除はコピーしません。

上の照合時点で walking skeleton は両 app に接続済みです。未送信 window ledger の reducer と snapshot codec は `shared/` にあり、iOS の production `SensingCoordinator` が shared runtime を使用します。iOS と Android には snapshot bytes を保存する native store がありますが、Android store の production 接続は Issue #121 へ残っています。iOS の `SensingCoordinator` は `BarnardIdentity` を直接保持せず、native 境界の `SensingCryptography` を一つ保持し、production では `BarnardSensingCryptography` を注入します。これは署名器を交換可能にする native facade であり、新しい shared 判断ではありません。

以下の family 一覧は移行台帳であり、この current-state 要約だけを根拠に他の family まで実装済みと扱いません。各 family の code、両 platform の production caller、test が揃うまで「動いている」と扱いません。

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

以下は family の移行先を示す**目標 layout**です。directory は対応する
family を実装する時にだけ作り、現在の file inventory として読まないで
ください。

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

次の「`commonMain` に置くもの」と「`shared/` に置かないもの」は、family を移す時の ownership 契約です。現在 production に配線済みの実装一覧ではありません。現在の配線状態は本書冒頭の実装照合だけで判断します。

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

### 両 OS を一つの feature として扱う

feature を追加または shared へ移す PR は、Android と iOS の production caller を両方更新します。一方を触らない場合は、PR description に理由を書きます。「今回は対象外」だけではなく、platform 固有の effect なのか、もう一方の production flow がまだ存在しないのかを明記します。shared test だけ通っても、どちらの app が実際にその判断を使うかは証明できないためです。

## 3. walking skeleton を作る

最初の PR は product rule を移しません。module boundary と build path だけを作ります。以下の 1–10 は walking skeleton を新設する時の一回限りの authoring 手順です。既存 checkout では作り直さず、その後の「完了条件」にある command を再実行して現在の配線を確認します。

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

Kotlin の package 配置は Swift source API の一部です。package を移すと生成される Swift の呼び方が変わるため、内部整理だけとは扱いません。生成 package namespace は lowercase で、同名の local binding に shadow されます。既定は `BeidSharedKit.report.SomeSharedType` のような module-qualified spelling です。同じ concrete type を何度も使う時だけ、`private typealias Ledger = BeidSharedKit.report.UnsentWindowLedger` のように右辺を完全修飾した private alias を使えます。package 全体の namespace alias は ownership の出所を隠すため作りません。

### walking skeleton の完了条件

repository root や `shared/` には Gradle wrapper がありません。Android app と shared の全 Gradle task（iOS target の Kotlin test を含む）は `android/gradlew` から実行します。

```bash
# repository root から開始する
cd android
JAVA_HOME="$(../scripts/resolve_kmp_java_home.sh)" \
  ./gradlew :app:compileDebugKotlin \
  :shared:testAndroidHostTest \
  :shared:iosSimulatorArm64Test \
  --no-daemon
cd ..
```

この command で Android app が `project(":shared")` を使って compile し、Android host test と iOS Simulator arm64 向け Kotlin test が実行されます。

Swift Export の復元確認では、derived output の `shared/build/SwiftExport` だけを消し、concrete Simulator UDID で app と tests を再 build します。

```bash
# repository root から開始する
rm -rf shared/build/SwiftExport
xcrun simctl list devices available
xcodebuild -project ios/Beid.xcodeproj -scheme Beid \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  build-for-testing
test -d shared/build/SwiftExport
```

Xcode build が **Build BeidSharedKit** phase で Swift Export を新規生成し、iOS app と tests が `BeidSharedKit` を import できれば完了です。

`compile-fixtures/` は walking-skeleton authoring の完了条件ではなく、該当する shared/native 境界を変更する PR で実行する手動 gate です。存在しない shared symbol、古い module 名、production の shared caller を壊す one-shot patch を disposable checkout へ適用し、各 fixture が指定する diagnostic を確認します。negative fixture の定期 CI gate 化は Issue #110 へ意図的に延期されており、現行 CI はこれらを実行しません。

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

### local Gradle

macOS の local build は repository の resolver で対応 JDK を選びます。resolver は対応する `KMP_JAVA_HOME`、Android Studio JBR 21、Homebrew JDK 17、macOS の Java 17 resolver の順に確認します。system Java 25 はこの Gradle / Kotlin 構成を起動できません。

```bash
# repository root から開始する
cd android
JAVA_HOME="$(../scripts/resolve_kmp_java_home.sh)" \
  ./gradlew :shared:testAndroidHostTest \
  :app:testDebugUnitTest \
  :app:assembleDebug \
  --no-daemon --no-parallel
cd ..
```

最後の `BUILD SUCCESSFUL` だけでは test 実行の証拠になりません。実行を期待した task に `NO-SOURCE` が出たら、その task は source / test を 0 件処理したという意味です。対象 task が `NO-SOURCE` でないことと、test report の件数を確認します。beid では空の test task が長く green に見えていたため、これは形式的な注意ではありません。

### local iOS

build 先は、`xcrun simctl list devices available` で得た concrete Simulator UDID を指定します。複数の simulator が同じ名前を持つため name-based destination は使いません。`generic/platform=iOS Simulator` は x86_64 も build 対象に含めることがあり、arm64-only binary dependency の link に失敗します。

```bash
# repository root から開始する
xcodebuild -project ios/Beid.xcodeproj -scheme Beid \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  build-for-testing
```

現在の local host には beta Xcode しか入っていないため、この command も active な beta toolchain で動きます。これは host の性質であり project requirement ではありません。local beta と Xcode Cloud の stable Xcode で結果が異なる場合、project compatibility の基準は Xcode Cloud の stable lane です。

link error が、この host の simulator に存在しない architecture を名指ししたら、symbol 名から自分の code を疑う前に destination を確認します。dependency が変わっても使える signal は error に出た architecture です。

### GitHub-hosted Ubuntu

beid は ShiokazeHD の self-hosted-only 制約の対象ではありません。現在の hosted job set と GitHub Actions / Xcode Cloud の分担は、repository の正本である [`AGENTS.md` の PR CI contract](../AGENTS.md#pr-ci) と実行定義 `.github/workflows/pr-ci.yml` を確認します。本書では task list を複製しません。KMP change は、上の local gate に加えてその PR CI contract を満たします。

toolchain は checkout だけから再現できるよう repo 内で pin します。Kotlin plugin version、Gradle wrapper と distribution checksum、CI の JDK version を暗黙の latest にしません。

### Xcode Cloud

Xcode Cloud の app build/test 自体が `:shared:embedSwiftExportForXcode` を実行しなければなりません。生成物を事前に commit して Xcode build phase を迂回してはいけません。

Xcode Cloud で確認するもの:

- XcodeGen の drift guard が通る。
- 対応 JDK を明示的に選び、ambient `JAVA_HOME` に依存しない。
- Swift Export が空でない。
- iOS app build と tests が fresh output に対して通る。
- ownership gate が iOS production caller を含めて通る。

Xcode Cloud の iOS lane は metered です。open PR の branch へ push すると実費のある build が起動し得るため、反復は local build で行い、push はまとめます。

自動 PR workflow では、green の有無を見る前に exact head SHA に iOS check が存在することを確認します。現在は workflow が無言で起動しない場合があり、Ubuntu の checks だけが green のまま残るためです。存在し、かつ同じ SHA で green になって初めて iOS gate を満たします。

将来 workflow を manual trigger へ変えた場合、この存在確認の読み方は逆になります。trigger 前の不在は正常です。その場合は、意図して起動した run が exact head SHA を対象にし、green になったことを記録します。自動起動を前提にした「不在は異常」という規則を、そのまま manual workflow に適用しません。

### test scope

変更した file には、その file の production behavior を覆う full covering suite を実行します。個別 test だけを指定してよいのは、その test の下にある code を変更していない時だけです。新しく書いた test class が green でも、同じ production file を覆う既存 suite の代わりにはなりません。

metered な CI の費用は、local で反復して push をまとめる理由にはなります。しかし、変更した code の regression coverage を狭める理由にはなりません。ledger slice では、費用を抑えるため targeted test を選んだ時、変更済みの native coordinator を覆う既存 test が実行対象から外れました。その既存 test が覆っていた App Review demo の停止 regression と durable record の重複は、suite ではなく後続 review で発見されました。

**A cost constraint quietly rewrote a correctness practice, and it looked reasonable at the time.**

### review gate

作者が手配した review は有用な self-check ですが、独立 review gate を満たしません。独立 review は repository maintainer に依頼します。具体的には PR を開き、maintainer が reviewer を割り当てるまで待ちます。作者は reviewer を選定・招待・手配しません。maintainer が依頼をどう処理するかは maintainer-side operation であり、本書の範囲外です。self-check と independent gate は別の evidence として報告します。

この train では二度、違いが具体化しました。walking-skeleton slice の maker-arranged audit は blocker なしでしたが、independent review は app-local class が shared type を置き換えても既存 check が green のままになる ownership hole を見つけました。ledger slice でも maker-arranged audit の後、independent review が二つの blocker を見つけ、その一つは shipped App Review path の regression と durable record の重複でした。どちらの self-check も不誠実ではなく、実装者の落ち度を示す事例でもありません。作者が review の範囲と入口を選ぶ構造と、独立した gate の構造が違うためです。

#### documentation audit の標準手順

将来の文書監査は **ANSWER-FROM-DOCS-THEN-VERIFY-AGAINST-CODE** の順で行います。reader は最初に文書だけを読み、具体的な質問へ回答し、各回答の確信度も明記して内容を固定します。その後で初めて source code と照合し、誤答・不足・過剰な確信が生まれた文書箇所を defect として記録します。

source を先に開くと、reader は既に知った答えの確認資料として文書を読み、文書だけから別の答えへ誘導される欠陥を見逃します。注意深い reader が文書だけで誤答した事実は、通常の accuracy pass では作れない evidence です。実際に wallet proof 署名を「未実装」とした本書群の P0 誤記は、両 platform を build した cold read と別の accuracy check の後にも残り、この順序の監査で初めて発見されました。

### path filter

current PR CI の job set と lane 分担は [`AGENTS.md` の PR CI contract](../AGENTS.md#pr-ci) を正本とし、ここでは複製しません。path 上の要点は、`shared/**`、`android/settings.gradle.kts`、Gradle wrapper/plugin version、JDK selector の変更が module build の前提を変えることです。repository の GitHub Actions workflow は PR に path filter を設けていません。Xcode Cloud の自動 PR workflow でも `shared/**` は start condition の対象ですが、無言で欠落する既知事象があるため、実際に exact head に存在することまで確認します。

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
# repository root から開始する
cd android
JAVA_HOME="$(../scripts/resolve_kmp_java_home.sh)" \
  ./gradlew :app:dependencyInsight \
  --dependency org.levarac:barnard \
  --configuration debugRuntimeClasspath
cd ..
```

最終的な merge gate は clean checkout の hosted-Ubuntu CI と Xcode Cloud に置きます。PR CI は `refs/pull/<N>/merge` の merge ref を build し、実際に着地する tree を検証します。報告は `CI green on <exact head SHA>, run <run id>` の形にし、PR checks の集約表示ではなく SHA で filter した run を確認します。集約表示は古い attempt を見せる場合があるためです。

Gradle cache があっても構いませんが、source checkout、dependency graph、local substitution が曖昧な build を証拠にしません。

## 8. 自分の branch の履歴に squash 済み commit が含まれる場合の rebase

最初に適用条件を判定します。前の slice が squash merge され、その squash 前の commit 群を自分の branch も履歴に含む場合だけ、この section の `--onto` 手順を使います。

```bash
# repository root から同じ shell session で開始する
git fetch origin
git log --oneline origin/main..HEAD
```

表示がすべて「現在の branch 自身の未着地作業として意図した commit」なら、この section は適用せず、素の `git rebase origin/main` を使います。前 slice など、現在の branch 自身の未着地作業として意図していない commit が含まれ、その slice が main では squash 済みなら、以下を適用します。

squash merge は N 個の commit を 1 個にまとめて main に載せます。自分の branch に残る元の N 個と main 側の 1 個は同じ commit ではないため、git は patch-id の一致で元の commit を適用済みと判定できません。素の rebase は、それらを自分の未着地 commit と一緒に replay します。結果は conflict が増えるだけとは限らず、取り消したはずの変更が復活することがあります。

実例として、2026-08-07 の kmp/03 では、前の kmp/02 が squash merge され、main には 1 個の commit として入りました。kmp/03 は kmp/02 系列の 9 個目の commit から分岐していました。素の `git rebase origin/main` は 10 個の commit を replay しようとし、その中には review で誤りと判断されて全面 revert 済みの commit も含まれていました。そのまま進めると、削除済みの不具合が、rebase した実装者の変更として復活するところでした。

### rebase の手順

まず branch 名と rebase 前の HEAD を記録します。

```bash
# 同じ shell session・repository root で続ける
branch_name="$(git branch --show-current)"
old_head="$(git rev-parse HEAD)"
```

本当の分岐点は、まず自分の branch の reflog から確認します。reflog は新しい順なので、最古の `branch: Created from ...` entry（通常は出力の最後）を探します。message が `Created from HEAD` でも、その行の先頭 SHA が branch 作成時の commit です。

ただし `branch: Created from refs/remotes/origin/<branch>` の entry は要注意です。その行の SHA は remote-tracking branch の**作成時の tip**であり、branch の fork point ではありません。見た目がもっともらしくても分岐点としてそのまま採用せず、どの creation message でも、その SHA が現在の履歴で「前 slice の最後と、この branch 自身の最初の commit の境界」になっていることを確認してから使います。

```bash
# 同じ shell session・repository root で続ける
git reflog show --format='%H %gs' "$branch_name"
```

reflog は local かつ期限付きなので、作成 entry が残っていない場合があります。その時は履歴を古い順に並べ、現在の branch 自身の最初の commit の直前にある、前 slice 最後の commit を選びます。

```bash
# 同じ shell session・repository root で続ける
git log --reverse --oneline origin/main..HEAD
```

どちらからも由来を確定できなければ SHA を推測せず停止します。stacked branch で `git merge-base origin/main "$branch_name"` を使ってはいけません。それが返すのは多くの場合、stack を作る前の古い main 上の共通祖先であり、本当の branch 作成点ではありません。その SHA を使うと前 slice の commit まで再び replay します。

分岐点を `fork_point` に記録してから rebase します。

```bash
# 同じ shell session・repository root で続ける
fork_point="<本当の分岐点のSHA>"
git rebase --onto origin/main "$fork_point" "$branch_name"
```

### rebase 後の確認

次の 4 点を必ず確認します。

```bash
# 同じ shell session・repository root で続ける
git range-diff "$fork_point..$old_head" origin/main..HEAD  # 自分の commit だけで patch が同一（= 印）
git rev-list --left-right --count origin/main...HEAD    # 0 behind であること
git log --oneline origin/main..HEAD                     # 自分の commit だけ載っていること
untouched_path="<自分が触っていない領域>"
git diff origin/main HEAD -- "$untouched_path"         # 空であること
```

4 番目の空 diff は、消したものが戻っていないことの**直接の証拠**です。他の 3 点が green だから大丈夫だろう、という推論の代わりにはなりません。

## 9. release branch へ forward-port する時

source branch で通った結果を destination branch の証拠として使いません。release branch では Kotlin、Gradle、Barnard、SwiftPM の resolved set が異なる場合があります。

1. destination branch の exact head を記録する。
2. その branch を base にする PR の merge ref を clean checkout する。
3. shared host tests、Android app build、full Xcode Cloud app build/test を merge ref で再実行する。
4. exact head SHA と CI run ID を記録し、SHA-filtered run が green であることを確認する。
5. published dependency を変更する場合は、destination で package manager が選んだ resolved version も記録する。
6. source と destination の resolved set が違えば、差を報告する。
7. destination で native 旧判断を復活させていないことを ownership gate で確認する。

この簡略化が成立するのは `shared/` が project-internal module の間だけです。将来 published artifact として配布するなら、clean checkout だけでは版を特定できないため、resolved-version capture を必須へ変更します。

## 10. PR checklist

- [ ] 台帳の family / class / oracle または invariant が埋まっている
- [ ] RED の falsifier を確認した
- [ ] shared vector に欠落・空・境界・unknown を含めた
- [ ] feature PR は Android / iOS の両方を更新した。片方を触らない場合は、その platform 境界または未配線の理由を PR description に書いた
- [ ] Android と iOS の production caller を全数確認した
- [ ] native adapter に判断が残っていない
- [ ] report の署名対象 payload と digest は shared が facilitator spec に従って作り、native signer は digest だけを受け取る
- [ ] 相互確認数、window / time-band 集計、Contributor Proof 数値、anchor edge は shared output であり、native は表示だけを行う
- [ ] Ethereum RPC transport は native、返却 bytes の decode / validation は shared に分かれている
- [ ] ledger snapshot codec は shared、保存場所と atomic write は native に分かれている
- [ ] Barnard-shaped code を shared に置かず、境界確認を null / length / container shape に限定して semantic re-check を重複させていない
- [ ] candidate scoring を含める場合、Issue #100 担当者の interface ACK が記録され、adoption / presentation を移していない
- [ ] OS / wallet / storage engine の責務を shared に移していない
- [ ] Android host test と app build が clean checkout で通り、期待した test task が `NO-SOURCE` でなく test 件数を記録した
- [ ] 変更した各 file を覆う full covering suite を実行した。個別 test だけに絞った場合は、その下の code を変更していないことを確認した
- [ ] Xcode Cloud が fresh Swift Export から app/test を build した
- [ ] 自動 Xcode Cloud workflow では exact head SHA に iOS check が存在し、green であることを確認した。manual workflow なら exact head を対象に起動した run を記録した
- [ ] PR を開いた後、repository maintainer が割り当てた独立 reviewer が gate を実施した。作者は reviewer を選定・手配せず、maker-arranged review は self-check として別に記録した
- [ ] exact head SHA と SHA-filtered CI run ID を記録した
- [ ] published dependency を変更した場合、resolved version と取得経路を記録した
- [ ] squash merge 済みの commit を履歴に含む branch を rebase した場合、rebase 後の 4 点をすべて確認した
- [ ] forward-port がある場合、destination branch の graph で再検証した

## 11. 参照した一次資料

- ShiokazeHD/umidori Issue #693: v0.10.0 shared runtime 置換の受け入れ条件と A/B/C 台帳
- ShiokazeHD/umidori Issue #780: iOS family ごとの stacked runtime-authority 切替
- ShiokazeHD/umidori PR #777: `shared/` 構造、Android 直接参照、Swift Export、ownership gate
- `ShiokazeHD/umidori@release/0.10.0`: `shared/build.gradle.kts`、Android settings/app、PR CI
- `Levarac/design-notes/2026-08-06-beid-reporting-claim-architecture.md`
- Kura `journal/2026-08-06-levarac-beid-android-ci-blind-spot.md`
- thegreeting/beid Issue #115: cold-start worker 向けの shared/native 境界と運用知識
- thegreeting/beid Issue #110: negative compile fixture の定期 CI gate 化（現時点では未実装）
