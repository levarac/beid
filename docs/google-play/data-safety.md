# Google Play Data safety — Ken 承認用の回答案

**DRAFT / 未承認・未入力・未公開。** 対象は Android `org.levarac.beid`。
[Issue #689（送信 ON とストア申告の整合）](https://github.com/thegreeting/beid/issues/689) の準備資料。
iOS の回答をそのまま転記しない。beid の固定 snapshot は
`45c39e698722883e930b36f45a3955929f601048`、確認日は 2026-09-26 UTC。
upstream freshness・operator の配備状態・実機送信の限界は
[App Privacy 案の調査対象](../app-store/privacy-labels.md#調査対象と限界) を参照。

## 承認リスト — 値と根拠

ここでの「選択」は入力候補であり、保存済みの Play Console 値ではない。
分類の当てはめは Ken の承認対象。`UNKNOWN` および `保留` を No に置き換えない。

| 項目 | 入力候補／判断待ち | 根拠 |
| --- | --- | --- |
| 収集・共有の有無 | **Yes** | 観測の自動 POST と保存（[B2](../app-store/privacy-labels.md#b2)、[B4](../app-store/privacy-labels.md#b4)、[O1](../app-store/privacy-labels.md#o1)） |
| 観測の種類 | **Personal info → User IDs** と **App activity → Other actions** を選択する案 | 仮名の参加者鍵・commitment とイベント参加履歴／近接観測（[B3](../app-store/privacy-labels.md#b3)） |
| 観測の扱い | **Collected + Shared / ephemeral: No / Required / App functionality** | 自動送信・無期限保持・公開 bundle 経路。共有目的も App functionality（[B2](../app-store/privacy-labels.md#b2)、[O1](../app-store/privacy-labels.md#o1)、[O2](../app-store/privacy-labels.md#o2)） |
| Location | **Approximate location を選択（Precise location は選択しない）** | オーナー判断（2026-09-27）。観測と同じ扱い（Collected + Shared / ephemeral: No / Required / App functionality）で申告する（B3） |
| 全データの転送暗号化 | **保留（オーナー判断で後日決定、2026-09-27）**。観測 HTTPS は確認済み | SDK／wallet relay／BLE を含めた全経路の保証は未確認（[B4](../app-store/privacy-labels.md#b4)、[W1–W3](../app-store/privacy-labels.md#w1)） |
| アカウント作成 | **My app does not allow users to create an account** を提案 | 下記 2a。wallet binding とサーバーアカウント作成を混同しない |
| データ削除の依頼手段／URL | **保留（オーナー判断で後日決定、2026-09-27）** | 公開窓口・手動運用は未確認。コードに削除 API は無く、無期限保持（[O1](../app-store/privacy-labels.md#o1)、[O3](../app-store/privacy-labels.md#o3)） |
| ウォレット情報・ログ由来の追加申告 | **保留（オーナー判断で後日決定、2026-09-27）** | 署名要求に wallet address／owner key が入り、IP 処理もある（[W3](../app-store/privacy-labels.md#w3)、O3） |
| フォームの最終値／順序 | **現行 Console の readback 待ち** | 以下は公式公開資料に沿った順序。接続可能なブラウザが無く、live form は未確認 |

Android の SDK 解析（MetaMask SDK analytics）はオーナー判断（2026-09-27）で申告しない。
main `77efbf61`（PR [#695](https://github.com/thegreeting/beid/pull/695)、
[#693](https://github.com/thegreeting/beid/issues/693) close）で解析を無効化しており、
次の Android 配布に含まれる。旧 build の挙動は [W2](../app-store/privacy-labels.md#w2) に
history として残す。詳細は下の「独立チェックの指摘」4. と Data types 表（3.13、3.14）を参照。

「共有なし」は提案しない。公開 bundle への転送を source から確認している。
配備差分、service-provider 例外、利用者が意図して行う共有の例外が適用できる証拠が揃った場合だけ、
該当種類の Shared を再検討する。仮名を完全匿名として例外扱いしない。

## 独立チェックの指摘（2026-09-26、承認前に反映すること）

独立 checker は同じ snapshot を読み、引用はすべて存在し主張を支えると確認した。
結論は **APPROVE WITH NOTES**、blocking は無い。
承認前に次を反映する。

1. **Android の位置情報権限。** Barnard 0.9.2 の AAR manifest が 2 つの権限をアプリに merge する。
   - `ACCESS_FINE_LOCATION`（maxSdk 30）
   - `ACCESS_COARSE_LOCATION`（maxSdk 28）

   アプリの minSdk は 26 である。上の Location 行が根拠にする `neverForLocation`（`android/app/src/main/AndroidManifest.xml:8-9`）は API 31 以上にしか効かない。
   beid 自身は位置情報を読まない。`LocationManager` / Fused provider の参照は無い。
   Play Console は宣言権限とデータセーフティの回答を突き合わせるので、Location の判断ではこの merge 済み権限を前提にする。
2. **UNKNOWN のうち、source から答えられるもの。**
   - 転送暗号化（2.2）: アプリが始める通信はすべて HTTPS 固定か HTTPS 強制である。
     - 送信
     - registry template
     - Sepolia RPC 2 本
     - Etherscan
     - ClockPreflight の HEAD
     - `HttpsVenueBundleAcquirer`
   - wallet の転送は両 OS とも端末内で完結する。network relay は無い。
     - iOS は `.deeplinking` を使う。
     - Android は `bindService` IPC を使う（`CommunicationClient.kt:505-532`）。
   - wallet address は同じ端末の MetaMask アプリにしか渡らない。Android の analytics 項目（`CommunicationClient.kt:109-124`, 214）に address は含まれない。
   - 小さな通信先 3 つも明記する。
     - ClockPreflight: operator origin への HEAD で、Date header を読む。
     - venue artifact の取得。
     - Etherscan: 既定では無効。`project.yml:104` と `beid.etherscanApiKey` の既定値は空文字。
3. **送信先はイベント定義が決める。** 送信 endpoint は検証済み Event Definition から来る（`SubmissionModels.kt:189-195`）。`validateSubmissionEndpoint` は任意の HTTPS URL を受け付ける。
   O1〜O3 は、現行の定義が名指す operator（levarac/parallax）の説明であって、固定の受信者ではない。Shared = Yes は最悪の場合も含む。
4. **Android の analytics は修正済み。** Issue [#693](https://github.com/thegreeting/beid/issues/693) は PR [#695](https://github.com/thegreeting/beid/pull/695) の merge（main `77efbf61`）で close した。
   オーナー判断（2026-09-27）により、配布中の build 構成にかかわらず Android の SDK 解析は申告しない。修正は次の Android 配布に含まれる。W2 は修正前の挙動の記録として残す。
5. **分類の OS 差。** 近接観測を iOS は「Other Data Types」、Android は「App activity → Other actions」に入れる。
   どちらもその platform の受け皿なので、Ken が並べて確認する。
6. **commitment と owner key のつながり。** 参加者 commitment は `H(event signing key ‖ owner key ‖ salt)` で作る（`OwnerKeyProvider.kt:22`、`EventCommitment.swift:7`）。wallet binding は owner key に署名する。
   B3 の「owner 公開鍵を追加するフィールドは無い」は文字どおりには正しいが、このつながりを示していない。Linked = Yes の提案は変えない。
7. **無いことの確認。**
   - 両 OS とも、MetaMask 以外のクラッシュ／解析 SDK は無い。
   - main に support bundle は無い。#466 で開発中で、入ったら再判定する。
   - Barnard の AAR に network code と INTERNET 権限は無い。
   - self-proof と binding の記録は端末外に出ない。
   - iOS の `PrivacyInfo.xcprivacy` は無い。この PR の範囲外。

## フォーム順序の出典と未確認範囲

以下の 1 → 2 → 3 → 4 → 5 は Google の
[Data safety 記入手順](https://support.google.com/googleplay/android-developer/answer/10787469?hl=en)
に沿う。2 と 4 の質問順、および 3 の列挙順は、同ページが配布する
[公式 sample CSV](https://storage.googleapis.com/support-kms-prod/b5v9It2EgwrgyY1gPFVB3jPUypc5lL3oNg2G)
を確認した。取得物は 763 回答行、SHA-256
`5eea7d426509e97523de02d31d2e94d574f096c111a6857f78929e735cf99e13`。
sample の TRUE/FALSE は例であり、beid の回答ではない。

**この sample は古いラベルを含み、現行画面の完全な質問順を証明しない。**
例えば Personal identifiers、Page views and taps in app は、現行ヘルプの User IDs、
App interactions と対応する。sample に無い account/deletion の追加分は 2a として分離した。
Google の [account deletion の説明](https://support.google.com/googleplay/android-developer/answer/13327111?hl=en)
では全開発者に追加質問を要求している。live Console の分岐順と完全な文言は **UNKNOWN**。
入力前に owner が実画面／その app から export した現行 CSV に照合する。
この資料を CSV import 用の完成データとして使わない。

## 1. Overview

説明を確認して次へ進む段階。収集なしとは答えない。
privacy policy の現行 URL・内容は **保留（オーナー判断で後日決定、2026-09-27）**。観測、SDK 解析、公開 bundle、保持と削除の説明が
本資料と一致するか確認する（[B3](../app-store/privacy-labels.md#b3)、[O1–O3](../app-store/privacy-labels.md#o1)、
[W2–W3](../app-store/privacy-labels.md#w2)）。
ストア内の現行リンクは今回読み取っていない。

## 2. Data collection and security

公開 sample CSV の質問順。質問は日本語で要約し、回答値を英語で示す。

| 順 | 質問 | 回答候補 | 根拠・未確認事項 |
| --- | --- | --- | --- |
| 2.1 | 対象の利用者データを収集または共有するか | **Yes** | [B2–B4](../app-store/privacy-labels.md#b2)、[O1–O2](../app-store/privacy-labels.md#o1)、[W2](../app-store/privacy-labels.md#w2) |
| 2.2 | 収集する全利用者データを転送中に暗号化するか | **保留（オーナー判断で後日決定、2026-09-27）** | 観測は HTTPS、SDK analytics の URL も HTTPS。ただし署名は暗号化ではない。wallet relay、BLE 交換、SDK の全通信は未確認（B4、W2–W3） |
| 2.3 | 利用者がデータ削除を依頼する方法があるか | **保留（オーナー判断で後日決定、2026-09-27）** | operator の保持は indefinite、store interface に削除操作なし。サポート窓口や手動対応の有無は別途確認する（O1、[O3](../app-store/privacy-labels.md#o3)） |

2.3 を No とするにも owner の確認が要る。端末内のデータ削除や uninstall は、
operator・SDK・公開済みコピーを削除する証拠にはならない。短期の自動削除も申告しない。

### 2a. 現行フォームの account/deletion 追加質問

以下は意味上の回答準備であり、live 画面内の挿入位置・分岐を確認したものではない。

| 質問の意味 | 入力候補 | 根拠 |
| --- | --- | --- |
| アプリで利用できる account creation の方法 | **My app does not allow users to create an account** | [Screen.kt:12–45](https://github.com/thegreeting/beid/blob/45c39e698722883e930b36f45a3955929f601048/android/app/src/main/kotlin/org/levarac/beid/navigation/Screen.kt#L12-L45) の参加・記録フローと [AccountScreen.kt:55–74](https://github.com/thegreeting/beid/blob/45c39e698722883e930b36f45a3955929f601048/android/app/src/main/kotlin/org/levarac/beid/ui/screens/AccountScreen.kt#L55-L74)。wallet binding は [W3](../app-store/privacy-labels.md#w3) の署名であり、beid のサーバーアカウント作成経路ではない |
| 外部で作った account に login できるか（表示される場合） | **No** を提案、wallet の位置付けを owner が確認 | [WalletHintStore.kt:5–10](https://github.com/thegreeting/beid/blob/45c39e698722883e930b36f45a3955929f601048/android/app/src/main/kotlin/org/levarac/beid/sensing/WalletHintStore.kt#L5-L10) は表示用キャッシュ。W3 は鍵の binding であり、beid backend のログインではない |
| account deletion URL（該当分岐が表示される場合） | **N/A を提案**。account ありと判断されるなら **保留（オーナー判断で後日決定、2026-09-27）** に戻す | 上の account 判定に従う。存在しない URL を作らない |
| account を削除せずデータだけ削除できるか／その URL | **保留（オーナー判断で後日決定、2026-09-27）** | O1、O3。窓口、処理範囲、保持例外、公開済みデータの扱いを owner が確認 |

guest-first だけでは全フローに account が無い証拠にならないため、wallet の意味も含めて承認する。
独立セキュリティ審査や Families の badge が表示された場合も、証明・対象設定を未取得なので
**UNKNOWN / 選択保留**。コードの単体テストを認証の代わりに使わない。

## 3. Data types

公式 sample のカテゴリ順。現在のヘルプでの種類名を使う。
「非選択案」は確認したデータ経路にその種類が無いという source ベースの案であり、
第三者・ログの全調査を完了したという宣言ではない。

| 順 | カテゴリ・種類 | 選択案 | 根拠 |
| --- | --- | --- | --- |
| 3.1 | Personal info — User IDs | **選択** | event observer key／commitment を仮名の参加者識別子として扱う案（[B3](../app-store/privacy-labels.md#b3)） |
| 3.1 | Name、Email address、Address、Phone number、Race and ethnicity、Political or religious beliefs、Sexual orientation | **非選択案** | B3 の閉じた本文と W2 の analytics パラメータには無い。event の属性から別の機微情報を導く運用があれば再評価 |
| 3.1 | Other info | **保留（オーナー判断で後日決定、2026-09-27）** | 近接関係の分類が Other actions で十分か、wallet の取扱いも含めて owner が確認（B3、[W3](../app-store/privacy-labels.md#w3)） |
| 3.2 | Financial info — User payment info、Purchase history、Credit score、Other financial info | **wallet 関連は保留（オーナー判断で後日決定、2026-09-27）**。購入履歴・信用情報は非選択案 | 観測に支払情報は無いが、wallet address／署名要求がある。残高・決済の収集は確認していない（B3、W3） |
| 3.3 | Location — Approximate location、Precise location | **Approximate location: 選択 / Precise location: 非選択** | オーナー判断（2026-09-27）。Approximate location を観測と同じ扱いで申告し、Precise location は申告しない（B3、[O3](../app-store/privacy-labels.md#o3)） |
| 3.4 | Web browsing — Web browsing history | **非選択案** | B3、W2。dapp metadata の固定 URL は利用者の閲覧履歴ではない |
| 3.5 | Messages — Emails、SMS or MMS、Other in-app messages | **非選択案** | B3、W2。W3 の署名 message は利用者間の会話ではない |
| 3.6 | Photos and videos — Photos、Videos | **非選択案** | B3、W2 |
| 3.7 | Audio files — Voice or sound recordings、Music files、Other audio files | **非選択案** | B3、W2 |
| 3.8 | Health and fitness — Health info、Fitness info | **非選択案** | B3、W2。近接観測を健康診断の記録とは扱っていない |
| 3.9 | Contacts | **保留（オーナー判断で後日決定、2026-09-27）** | アドレス帳フィールドは無いが、RPID の近接関係はある（B3、[O2](../app-store/privacy-labels.md#o2)） |
| 3.10 | Calendar — Calendar events | **非選択案** | B3 は beid のイベントであり、利用者のカレンダー内容を読む経路ではない |
| 3.11 | App info and performance — Crash logs、Diagnostics、Other app performance data | **保留（オーナー判断で後日決定、2026-09-27）** | operator／SDK／RPC のログ保持・利用を確認。診断利用の全体は未確認（O3、W2） |
| 3.12 | Files and docs | **非選択案** | B3 のアプリ生成 CBOR は、利用者の文書ファイルのアップロードではない |
| 3.13 | App activity — App interactions | **非選択案** | MetaMask 接続／承認／失敗／RPC イベントの送信（[W2](../app-store/privacy-labels.md#w2)）はオーナー判断（2026-09-27）で申告しない。main `77efbf61`（PR #695）で無効化済み |
| 3.13 | App activity — In-app search history | **保留（オーナー判断で後日決定、2026-09-27）** | event code／hash lookup の送信はある。検索履歴として保持・利用するかは未確認（[B5](../app-store/privacy-labels.md#b5)） |
| 3.13 | App activity — Installed apps、Other user-generated content | **非選択案** | B3、W2。SDK が MetaMask を起動することだけでは、インストール済みアプリ一覧の収集を立証しない |
| 3.13 | App activity — Other actions | **選択** | 参加・近接・観測時刻の分類案（B2–B3、O1） |
| 3.14 | Device or other IDs | **非選択案** | SDK の session／channel ID（W2）はオーナー判断（2026-09-27）で申告しない。main `77efbf61`（PR #695）で無効化済み。MAC／IMEI／広告 ID の収集を確認したという意味ではない |

Play に汎用の「その他」という一つの欄があると仮定しない。
位置情報は Google の 3 平方 km の区切りで判定する。小さな会場まで絞れる情報なら
Approximate では足りない可能性がある。Apple の境界とも同じではない。
オーナー判断（2026-09-27）により Approximate location を申告し、Precise location は申告しない。

## 4. Data usage and handling

選択種類について、公式 sample の順番で次の 5 問に答える。
全種類をひとまとめに同じ回答で埋めない。

| 順 | 質問の意味 | User IDs / Other actions（観測） |
| --- | --- | --- |
| 4.1 | 収集・共有のどちらか | **Collected と Shared の両方** |
| 4.2 | 一時処理だけか | **No** |
| 4.3 | 収集が必須か、利用者が選べるか | **Data collection is required** |
| 4.4 | 収集する目的 | **App functionality** |
| 4.5 | 共有する目的 | **App functionality** |

観測列の根拠は [B2–B4](../app-store/privacy-labels.md#b2) と
[O1–O2](../app-store/privacy-labels.md#o1)。アプリの中核である参加証拠の送信に明示的な
opt-out は無く、参加しない選択があるだけで Optional としない。公開検証に向けた bundle は
観測そのものを含む。稼働環境での公開状況と例外の適用は確認待ちとして残す。

Android の SDK 解析（App interactions、Device or other IDs）はオーナー判断（2026-09-27）で
申告しないため、この表に SDK 列は無い。main `77efbf61`（PR #695、Issue #693 close）で無効化
済みで、次の Android 配布に含まれる。上の Data types 表（3.13、3.14）と [W2](../app-store/privacy-labels.md#w2) を参照。

Location はオーナー判断（2026-09-27）で Approximate location を採用した。観測からの推定に
ついて観測列と同じ 5 回答（Collected + Shared / ephemeral: No / Required / App functionality）
を使う。
wallet データ、IP、Diagnostics 等を追加する場合は、それぞれの実際の経路で 5 問を追加調査する。
複数経路が同じデータ種類に合流する場合は、目的を合算し、一時処理／任意性も全経路を満たす必要がある。
例えば後で観測鍵を Device or other IDs に分類し直すなら、その行も観測側の
非 ephemeral・Required・App functionality を反映する。

広告、開発者からの連絡、personalization、account management は確認した経路では選択しない案。
ただし第三者の利用・契約の確認を終えたという意味ではない。
IP rate limit の security 目的等は、IP の保存・申告種類を確定してから追加する（O3）。

## 5. Preview

**現時点では保存・送信しない。** source に基づく下記の要点を preview と照合する準備ができた段階。

- 収集あり。観測の仮名識別子・参加行動と Approximate location を含む。Android SDK 解析は
  オーナー判断（2026-09-27）で申告しない。
- 公開 bundle のため、共有なしとはしない。
- 全転送暗号化・削除手段の badge はオーナー判断で保留（2026-09-27）。HTTPS の観測経路だけで
  Yes を確定しない。
- wallet、ログの種類／用途、現行フォームの全分岐が未確定。

## OS 差と引き渡し

iOS は MetaMask 0.8.10 の analytics を無効化し、Android 0.6.6 は既定で有効だった
（[W1–W2](../app-store/privacy-labels.md#w1)）。Android は main `77efbf61`（PR #695、
Issue #693 close）で同じ無効化に揃え、次の Android 配布に含まれる。観測本文は両 OS 共通だが、
利用する SDK と通信経路は同一ではない。この資料のためにコードは変更していない。

Ken／owner が確定する残件は、現行 Console の順序・条件分岐、公開文面、実配布 build、
event と会場の解像度、operator の公開・削除・ログ運用、SDK／RPC の保存・二次利用・転送保護。
証拠を得たら UNKNOWN・保留を具体値へ置き換え、更新後の入力一覧を承認する。
この PR はストア反映も実機受理確認も行わず、Issue #689 を閉じない。
