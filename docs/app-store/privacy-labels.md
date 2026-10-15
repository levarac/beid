# App Privacy — Ken 承認用の申告案

**DRAFT / 未承認・未入力・未公開。** [送信 ON とストア申告の整合（Issue #689）](https://github.com/thegreeting/beid/issues/689)
の申告準備資料。コード上の事実とストア分類への当てはめを分ける。
`UNKNOWN` および `保留` は「いいえ」の意味ではない。未確認事項を解消し、Ken が値を承認してから入力する。
Google Play は [Data safety 回答案](../google-play/data-safety.md) を使う。

## 承認リスト

英語は画面の選択肢名。CLI のトークンを推測したものではない。

| 項目 | Ken に承認を求める入力値 | 根拠・確度 |
| --- | --- | --- |
| データ収集 | **Yes, we collect data from this app** | 確認済み。観測を POST し operator が保存する（B1–B4、O1） |
| 近接証拠 | **Other Data Types** | 分類案。RPID 集合・署名付き観測の残余部分。下の識別子・参加履歴・位置情報の代用にはしない（B3） |
| イベント内の参加者識別子 | **Identifiers → User ID** | 分類案。`observer` と参加コミットメントはイベント内の識別に使える。アカウントが無いだけでは除外できない（B2–B3） |
| イベント参加・時刻 | **Usage Data → Other Usage Data** | 分類案。アプリを使った参加履歴を保持する（B3、O1） |
| 上記各種類の利用目的 | **App Functionality** | 参加証拠の作成・送信・受理・検証（B2–B4、O2） |
| 上記各種類がユーザーに紐づくか | **Yes** を提案 | 実名との結合を確認したという意味ではない。イベント内で同じ鍵に紐づき、匿名化・再結合防止を立証できていないため、旧案の断定的な No を撤回する（B3、O1–O2） |
| トラッキングに使うか | **No** を暫定提案、第三者の利用確認まで保留 | iOS SDK の解析は無効。確認した経路に広告目的はないが、第三者による二次利用は UNKNOWN（W1、U3） |
| Location | **Coarse Location を選択（Precise Location は選択しない）** | オーナー判断（2026-09-27）。観測と同じ扱い（Linked to user: Yes、Used for: App Functionality）で申告する（B3、U1） |
| Contacts / Search History / Diagnostics / Device ID | **保留（オーナー判断で後日決定、2026-09-27）** | 近接 graph、event lookup、IP／SDK 経路がある。観測の User ID 分類だけで全識別子を説明したとはしない（B3、B5、O3、W1–W3） |
| ウォレット・通信ログ由来の追加種類／目的 | **保留（オーナー判断で後日決定、2026-09-27）** | 観測本文にウォレットが無いことはアプリ全体で送信しない証明ではない（W1–W3、U2–U3） |
| その他の選択肢 | **非選択案**。Contact Info、Health & Fitness、Sensitive Info、User Content、Browsing History、Purchases、Advertising Data、Surroundings、Body の収集は確認していない | B3 の本文と W1 の analytics 無効化に基づく限定的な案。Financial Info は wallet 経路の確認まで保留（オーナー判断で後日決定、2026-09-27）。第三者の全利用を確認済みとはしない（U1–U3） |
| Privacy Policy URL / Privacy Choices URL | **保留（オーナー判断で後日決定、2026-09-27）** | 公開ページ・ASC 保存値は今回取得していない。削除可能という文言も未確定（U2） |

そのまま公開できる完成済みフォームではない。location、第三者の保存・利用、公開 bundle、
削除窓口の確認を伴わない一括承認はしない。

独立チェック（2026-09-26）の結論は APPROVE WITH NOTES で、blocking は無い。
指摘の全文は [Data safety 案の該当節](../google-play/data-safety.md#独立チェックの指摘2026-09-26承認前に反映すること) にある。
iOS に関わる点は次のとおり。

- 転送暗号化は source で確認済み。すべての通信経路が HTTPS である。
- wallet は `.deeplinking` による端末内の往復で、network relay は無い。
- 送信先は検証済み Event Definition が決める。O1〜O3 は現行 operator の説明であり、固定の受信者ではない。
- commitment は owner key と結びつく（`EventCommitment.swift:7`）。Linked = Yes の根拠になる。
- `PrivacyInfo.xcprivacy` は無い。この PR の範囲外。

## 調査対象と限界

2026-09-26 UTC に確認。beid は担当に指定された main 由来の
`45c39e698722883e930b36f45a3955929f601048` を固定して読んだ。
共有 Git 管理領域への fetch が自動承認審査で拒否されたため、lead の裁定でこの snapshot を使用した。
最新 main との一致を独立に再確認したという意味ではない。

operator は read-only の GitHub 読み取りで得た `levarac/parallax`
`fde68bf595c4587c502c9c35c2ac840cc4737a2b`。
source の確認であり、配備された Worker、D1 の実データ、Cloudflare 設定の確認ではない。
実際の観測・鍵・ウォレット値は収集していない。実機通信の捕捉、ASC／Play の保存値の読取り、
ストアへの書込みは実施していない。

分類は Apple の [App privacy details](https://developer.apple.com/app-store/app-privacy-details/)
と [App Privacy の管理手順](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/)
に照合した。仮名だけでは unlinked と断定できない。目的・紐付け・tracking は別の質問であり、
公開と広告用 tracking も同義ではない。

## コード上の根拠

リンクは固定 SHA の file:line。B は beid、O は operator、W はウォレット経路。
Play 回答案もこの根拠番号を参照する。

### B1

**iOS の本番ターゲットは送信 ON。**
[ios/project.yml:125](https://github.com/thegreeting/beid/blob/45c39e698722883e930b36f45a3955929f601048/ios/project.yml#L125)
は YES。[SensingCoordinator.swift:955](https://github.com/thegreeting/beid/blob/45c39e698722883e930b36f45a3955929f601048/ios/Beid/Sensing/SensingCoordinator.swift#L955)
が runtime を構築し、[同:3837–3844](https://github.com/thegreeting/beid/blob/45c39e698722883e930b36f45a3955929f601048/ios/Beid/Sensing/SensingCoordinator.swift#L3837-L3844)
が窓を閉じる際に呼ぶ。
[ReportSubmissionRuntime.swift:185–200](https://github.com/thegreeting/beid/blob/45c39e698722883e930b36f45a3955929f601048/ios/Beid/Sensing/ReportSubmissionRuntime.swift#L185-L200)
の条件は build flag と definition provider であり、利用者の送信 opt-out ではない。
Lab ターゲットの NO（project.yml:207）は本番の回答に使わない。

### B2

**Android にも本番の writer と送信処理がある。**
[EventJoinCoordinator.kt:143–153](https://github.com/thegreeting/beid/blob/45c39e698722883e930b36f45a3955929f601048/android/app/src/main/kotlin/org/levarac/beid/sensing/EventJoinCoordinator.kt#L143-L153)
が app の保存領域を渡し、[同:276–286](https://github.com/thegreeting/beid/blob/45c39e698722883e930b36f45a3955929f601048/android/app/src/main/kotlin/org/levarac/beid/sensing/EventJoinCoordinator.kt#L276-L286)
が runtime を取得する。
[WindowObservationAccumulator.kt:155–199](https://github.com/thegreeting/beid/blob/45c39e698722883e930b36f45a3955929f601048/android/app/src/main/kotlin/org/levarac/beid/sensing/WindowObservationAccumulator.kt#L155-L199)
で保存と drain を接続し、窓が閉じると自動で drain する。
[WindowObservationSubmissionDrain.kt:240–244](https://github.com/thegreeting/beid/blob/45c39e698722883e930b36f45a3955929f601048/android/app/src/main/kotlin/org/levarac/beid/sensing/WindowObservationSubmissionDrain.kt#L240-L244)
が lookup または POST を実行する。

**両 OS の実入力。**
[ReportSubmissionRuntime.swift:308–324](https://github.com/thegreeting/beid/blob/45c39e698722883e930b36f45a3955929f601048/ios/Beid/Sensing/ReportSubmissionRuntime.swift#L308-L324)
と [WindowObservationAccumulator.kt:473–483](https://github.com/thegreeting/beid/blob/45c39e698722883e930b36f45a3955929f601048/android/app/src/main/kotlin/org/levarac/beid/sensing/WindowObservationAccumulator.kt#L473-L483)
はイベント署名鍵、event ID、時刻、自己／周辺 RPID、参加コミットメントを shared に渡す。
iOS は rpidClaimHex を nil、Android は factory の null default
（[MutualSensingObservation.kt:143](https://github.com/thegreeting/beid/blob/45c39e698722883e930b36f45a3955929f601048/shared/src/commonMain/kotlin/org/levarac/parallax/observation/MutualSensingObservation.kt#L143)）を使う。

### B3

**送信本文は集計件数だけではない。**
[MutualSensingObservation.kt:50–108](https://github.com/thegreeting/beid/blob/45c39e698722883e930b36f45a3955929f601048/shared/src/commonMain/kotlin/org/levarac/parallax/observation/MutualSensingObservation.kt#L50-L108)
は次を canonical CBOR／COSE に含める。
署名・保存の実呼出しは
[ReportSubmissionRuntime.swift:340–352](https://github.com/thegreeting/beid/blob/45c39e698722883e930b36f45a3955929f601048/ios/Beid/Sensing/ReportSubmissionRuntime.swift#L340-L352)。

| 部分 | 実際の値 | 申告上の意味 |
| --- | --- | --- |
| Observation | version、窓 UUID、profile、event ID（context）、イベント署名公開鍵（observer）、秒単位の時刻、自己 RPID（subject） | イベント参加、時間、仮名の参加者識別 |
| Mutual-sensing payload | 定義 digest、ENIN（観測の時間区間）、観測した RPID の完全な集合、null の rpidClaim、任意の参加コミットメント | 周辺端末との近接関係。件数のみへの匿名化は行わない |
| COSE header／署名 | content type、アルゴリズム、公開鍵由来の kid、署名 | 検証とイベント内の結合 |

この閉じた本文には、名前・メール・電話・GPS 座標・広告 ID・ウォレットアドレス・owner 公開鍵を追加する
フィールドは無い。ただしこれは**観測本文だけの否定**。IP、SDK 通信、ウォレット署名要求を除外する根拠ではない。
RPID は端末間で交換する仮名であり、端末のアドレス帳を読んだものではない。
Apple の Contacts に含まれる social graph への該当性も、公開 bundle の利用を含め U1 で確認する。

### B4

**観測と receipt lookup は HTTPS。**
[SubmissionClient.kt:64–95](https://github.com/thegreeting/beid/blob/45c39e698722883e930b36f45a3955929f601048/shared/src/commonMain/kotlin/org/levarac/parallax/submission/SubmissionClient.kt#L64-L95)
は signed bytes を POST し、再確認時には観測 digest を URL に含めて GET する。
[SubmissionModels.kt:234–245](https://github.com/thegreeting/beid/blob/45c39e698722883e930b36f45a3955929f601048/shared/src/commonMain/kotlin/org/levarac/parallax/submission/SubmissionModels.kt#L234-L245)
は本番 endpoint に HTTPS を要求する。HTTP 例外は明示的に有効にする loopback test 用。
署名は暗号化ではなく、operator は本文を読める。

### B5

**観測以外の registry 通信もある。**
[iOS RegistryDependencies.swift:49–55](https://github.com/thegreeting/beid/blob/45c39e698722883e930b36f45a3955929f601048/ios/Beid/App/RegistryDependencies.swift#L49-L55)
と [Android RegistryDependencies.kt:9–15](https://github.com/thegreeting/beid/blob/45c39e698722883e930b36f45a3955929f601048/android/app/src/main/kotlin/org/levarac/beid/registry/RegistryDependencies.kt#L9-L15)
が event code／hash lookup、定義・鍵の取得を設定する。
[ios/project.yml:117–134](https://github.com/thegreeting/beid/blob/45c39e698722883e930b36f45a3955929f601048/ios/project.yml#L117-L134)
と [android/app/build.gradle.kts:24–30](https://github.com/thegreeting/beid/blob/45c39e698722883e930b36f45a3955929f601048/android/app/build.gradle.kts#L24-L30)
に operator URL、
[RegistryClient.kt:393–398](https://github.com/thegreeting/beid/blob/45c39e698722883e930b36f45a3955929f601048/shared/src/commonMain/kotlin/org/levarac/parallax/registry/RegistryClient.kt#L393-L398)
に外部 RPC endpoint がある。受信側にはアクセス元 IP 等も見える。保持・二次利用は U2–U3。

### O1

**operator は受理した観測と receipt を保持する。**
[operator-store.ts:3–29](https://github.com/levarac/parallax/blob/fde68bf595c4587c502c9c35c2ac840cc4737a2b/operator/src/operator-store.ts#L3-L29)
が自然キー、digest、context、signedObservation、acceptanceReceipt、acceptedAt、mergeBy、
任意の delegationCert と definitionDigest を規定する。
[0001_initial.sql:6–24](https://github.com/levarac/parallax/blob/fde68bf595c4587c502c9c35c2ac840cc4737a2b/operator/migrations/0001_initial.sql#L6-L24)
に観測・receipt・bundle の保存列があり、
[0006_observation_delegation_cert.sql:7](https://github.com/levarac/parallax/blob/fde68bf595c4587c502c9c35c2ac840cc4737a2b/operator/migrations/0006_observation_delegation_cert.sql#L7)
が証明書列を追加する。アプリの B4 の POST 本文が別途 delegationCert を送るわけではない。
[http-handler.ts:653–665](https://github.com/levarac/parallax/blob/fde68bf595c4587c502c9c35c2ac840cc4737a2b/operator/src/http-handler.ts#L653-L665)
の health 実装は retention を indefinite とする。これは live health の今回の読取りではない。
コードの保持契約から、観測を一時処理・短期自動削除とは申告できない。

### O2

**operator への送信が公開の読取り経路につながる。**
[http-handler.ts:621–640](https://github.com/levarac/parallax/blob/fde68bf595c4587c502c9c35c2ac840cc4737a2b/operator/src/http-handler.ts#L621-L640)
は public GET の CORS を許可し、
[同:859–907](https://github.com/levarac/parallax/blob/fde68bf595c4587c502c9c35c2ac840cc4737a2b/operator/src/http-handler.ts#L859-L907)
は保存された bundle と event verification を返す。bundle の route に利用者認証は無い。
verification には anchor／admission 等の成立条件があるので、全イベントが今公開済みとは言わない。
[operator-store.ts:32–40](https://github.com/levarac/parallax/blob/fde68bf595c4587c502c9c35c2ac840cc4737a2b/operator/src/operator-store.ts#L32-L40)
の pending records は署名済み観測そのもの。
[operator-core.ts:868–882](https://github.com/levarac/parallax/blob/fde68bf595c4587c502c9c35c2ac840cc4737a2b/operator/src/operator-core.ts#L868-L882)
も bundle と signedObservation を読取り結果に載せる。
Levarac 自身が受信することだけを理由に、第三者への共有を No としてはいけない。
実際の bundle は取得していない。公開環境との一致と公開に対する同意の扱いは U2。

### O3

**IP を扱うコードがある。削除を約束する証拠は無い。**
[workers-entry.ts:584–585](https://github.com/levarac/parallax/blob/fde68bf595c4587c502c9c35c2ac840cc4737a2b/operator/src/workers-entry.ts#L584-L585)
が cf-connecting-ip を rate limit に渡す。
[operator-store.ts:154–175](https://github.com/levarac/parallax/blob/fde68bf595c4587c502c9c35c2ac840cc4737a2b/operator/src/operator-store.ts#L154-L175)
に利用者データ削除操作は無く、O1 の保持契約も無期限。
窓口による手動対応、Cloudflare／RPC のログ、バックアップ削除まで不可能だと証明するものではない。

### W1

**iOS は MetaMask の analytics を無効にしているが、ウォレット要求自体はある。**
[MetaMaskConnector.swift:338–346](https://github.com/thegreeting/beid/blob/45c39e698722883e930b36f45a3955929f601048/ios/Beid/Onboarding/MetaMaskConnector.swift#L338-L346)
は deep linking と enableDebug: false を使う。pin は
[Package.resolved:14–19](https://github.com/thegreeting/beid/blob/45c39e698722883e930b36f45a3955929f601048/ios/Beid.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved#L14-L19)
の 0.8.10 / `924d91bb3e98a5383c3082d6d5ba3ddac9e1c565`。
SDK の [Analytics.swift:30–37](https://github.com/MetaMask/metamask-ios-sdk/blob/924d91bb3e98a5383c3082d6d5ba3ddac9e1c565/Sources/metamask-ios-sdk/Classes/Analytics/Analytics.swift#L30-L37)
は debug が false なら送信しない。
[MetaMaskConnector.swift:367–392](https://github.com/thegreeting/beid/blob/45c39e698722883e930b36f45a3955929f601048/ios/Beid/Onboarding/MetaMaskConnector.swift#L367-L392)
は connectAndSign／personalSign を SDK に渡す。

### W2

**更新（2026-09-26）:** main `77efbf61`（PR [#695](https://github.com/thegreeting/beid/pull/695)、Issue [#693](https://github.com/thegreeting/beid/issues/693) を close）で、Android も SDK 構築直後に `enableDebug(false)` を呼ぶようになった。
独立 checker は次を確認している。
- `Analytics.trackEvent` は唯一の HTTPS 送信経路で、`Analytics.kt:35` の `if (!enableDebug) return` によって送信前に戻る。
- 最初の送信より前にこのフラグが立つ。
- 修正を外すとテストが RED になる。

以下は修正**前**の build（`45c39e69` 以前から作った Android build）の記述で、それらの build が配布に残っている間は有効である。

**修正前の Android は同じ analytics 無効化をしていない。**
[android/app/build.gradle.kts:134](https://github.com/thegreeting/beid/blob/45c39e698722883e930b36f45a3955929f601048/android/app/build.gradle.kts#L134)
の SDK 0.6.6 と
[WalletConnector.kt:79–101](https://github.com/thegreeting/beid/blob/45c39e698722883e930b36f45a3955929f601048/android/app/src/main/kotlin/org/levarac/beid/sensing/WalletConnector.kt#L79-L101)
を確認した。SDK tag 0.6.6 の commit は `a448378fbedc3afbf70759ba71294f7819af2f37`。
[Ethereum.kt:54–58](https://github.com/MetaMask/metamask-android-sdk/blob/a448378fbedc3afbf70759ba71294f7819af2f37/metamask-android-sdk/src/main/java/io/metamask/androidsdk/Ethereum.kt#L54-L58)
の enableDebug は true が既定値。
[CommunicationClientModule.kt:22–23](https://github.com/MetaMask/metamask-android-sdk/blob/a448378fbedc3afbf70759ba71294f7819af2f37/metamask-android-sdk/src/main/java/io/metamask/androidsdk/CommunicationClientModule.kt#L22-L23)
も既定の Analytics() を構築する。
[Analytics.kt:23–38](https://github.com/MetaMask/metamask-android-sdk/blob/a448378fbedc3afbf70759ba71294f7819af2f37/metamask-android-sdk/src/main/java/io/metamask/androidsdk/Analytics.kt#L23-L38)
は HTTPS の MetaMask analytics endpoint に送る。
[CommunicationClient.kt:109–124](https://github.com/MetaMask/metamask-android-sdk/blob/a448378fbedc3afbf70759ba71294f7819af2f37/metamask-android-sdk/src/main/java/io/metamask/androidsdk/CommunicationClient.kt#L109-L124)
に session／channel ID、時刻、SDK version、platform、app metadata／package ID があり、
[Ethereum.kt:296–310](https://github.com/MetaMask/metamask-android-sdk/blob/a448378fbedc3afbf70759ba71294f7819af2f37/metamask-android-sdk/src/main/java/io/metamask/androidsdk/Ethereum.kt#L296-L310)
と [同:374–382](https://github.com/MetaMask/metamask-android-sdk/blob/a448378fbedc3afbf70759ba71294f7819af2f37/metamask-android-sdk/src/main/java/io/metamask/androidsdk/Ethereum.kt#L374-L382)
が接続結果／RPC method のイベントを発火する。
広告 ID やウォレット残高の送信を確認したわけではない。source による経路の確認であり、
端末からの実送信や受信先の保持期間は未測定。

### W3

**ウォレットアドレスと owner 公開鍵は観測本文の外の署名要求に入る。**
[iOS SensingCoordinator.swift:3403–3414](https://github.com/thegreeting/beid/blob/45c39e698722883e930b36f45a3955929f601048/ios/Beid/Sensing/SensingCoordinator.swift#L3403-L3414)
と [Android EventJoinCoordinator.kt:1062–1078](https://github.com/thegreeting/beid/blob/45c39e698722883e930b36f45a3955929f601048/android/app/src/main/kotlin/org/levarac/beid/sensing/EventJoinCoordinator.kt#L1062-L1078)
は wallet address、owner public key、chain ID、nonce、issuedAt を使って binding message を作る。
Android の実呼出しは
[WalletConnector.kt:323–353](https://github.com/thegreeting/beid/blob/45c39e698722883e930b36f45a3955929f601048/android/app/src/main/kotlin/org/levarac/beid/sensing/WalletConnector.kt#L323-L353)、iOS は W1。
端末内の表示用キャッシュがあることから「ウォレット情報は端末外へ一切出ない」と一般化しない。
SDK／ウォレットの relay、保持、暗号化、利用者の操作による共有例外の適用は U3。

## 両 OS の差

| 対象 | iOS | Android |
| --- | --- | --- |
| 観測の送信 | build flag YES から構築（B1） | app filesDir から writer と drain を構築（B2） |
| 観測データ | B3 の共通形式、rpidClaim は null | 同左 |
| ウォレット SDK | 0.8.10、deep linking、analytics 無効（W1） | 0.6.6、既定の analytics が有効（W2） |
| ウォレット binding | owner key 等を署名要求へ渡す（W3） | 同左。通信実装は別 SDK |

両 OS のコードを変更しない docs-only 作業。SDK 設定を変更する場合は別の実装・検証を行い、
その対象 build に合わせて申告案も更新する。

## 未確認事項 — 入力前に解消する

- **U1 分類**: event key を User ID とする案、近接証拠／参加履歴の分類、Contacts の social graph 該当性、
  event→会場の解像度を owner が承認する。Location は Coarse Location としてオーナー判断済み
  （2026-09-27）。Apple の precise/coarse は座標の小数 3 桁相当を境にするが、GPS を読まないこと、
  Android の neverForLocation 宣言だけでこの分類を導いたわけではない。
- **U2 運用**: 配備中の operator と O1–O3 の一致、公開 bundle の範囲・第三者への提供、Cloudflare／RPC／SDK の
  ログと保持期間、削除窓口・URL・実施範囲、バックアップ・公開済みコピーの扱いを確認する。
  ログの用途を見ずに Diagnostics に固定しない。IP の用途次第で Location／Identifiers 等にもなる。
- **U3 SDK と全通信**: wallet transport／relay の全経路と受信側保持・二次利用を確認する。
  iOS の analytics 無効化は SDK の全通信停止を意味しない。Android の analytics を無かったことにしない。
  広告用結合・broker 提供を含む tracking の最終判断にもこの確認が要る。
- **U4 公開文面と対象 build**: privacy policy、アプリ内説明、審査メモ、ストアの現行保存値と配布中の全 build を
  突き合わせる。今回の source 調査は実機受理や公開済みラベルを証明しない。

旧案の「送るのは観測だけ」「ユーザーに紐づかない」「自社 operator なので第三者共有なし」は撤回する。
[古い schema 検討:32–39](https://github.com/thegreeting/beid/blob/45c39e698722883e930b36f45a3955929f601048/docs/decisions/issue-145-privacy-schema.md#L32-L39)
の送信 OFF／Android caller 不在／公開機構不在は当時の記録であり、B1–B2・O2 の現状に代えて使わない。

## 承認後の実施境界

ASC の現在の選択肢・保存値を読み取り、承認済みの画面選択肢と照合する。
CLI を使う場合の手順は [README](README.md) にあるが、この draft は実行指示でも publish 承認でもない。
Issue #689 は、ストア反映と未確認事項の解消、別担当の実機受理確認が残るため、この資料の PR では閉じない。
