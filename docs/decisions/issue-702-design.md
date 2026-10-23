# beid#702 — 14 Organizer tools の `VENUE KEY` 欄: 鍵ではなく、保存済みの配信パックの状態を出す(Implemented)

読む人: PM, and any agent touching this area in the future.
書いた人: Worker a-20260927-006。作成日 2026-09-27。
Status: **Implemented in PR #705.** Landed as `5b1abdce` (the #702 change itself) and `af6934dc`
(per-launch UI test store isolation). The Open decisions below (O1–O5) each get an "Implementation"
note recording the choice actually taken — see the end of each item.
測った対象: beid ブランチ `work/issue-702-venue-key`、コミット `62531fe`(#679 のマージ commit `27c1525` を含むことを `git merge-base --is-ancestor` で確認済み)。
Barnard はタグ `v0.9.2`(`61e2f0bacde14d78b18278bf743f587380f76cba`)。`ios/project.yml:8-10` の `exactVersion: 0.9.2` と
`ios/Beid.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved:5-11` の revision が一致する。
ローカルの `~/Workspace/levarac/barnard` は v0.9.2 より 10 commit 進んでいるため、Barnard の引用はすべて
`git -C ~/Workspace/levarac/barnard show v0.9.2:<path>` で読んだ行番号である(作業ツリーではない)。
Figma は `xf2uFHceIYg0h0gJndUkmI`(#626 本文のリンク)を Figma MCP で直接読んだ(2026-09-27)。

**This document originally said it did not change app code (implementation was to follow PM
confirmation).** That confirmation has since been given and implementation is complete (see
Status above). The body below is left as written at design time; the choice actually taken is
recorded as an addition to each Open decision item.

---

## 0. 決定の要約と、食い違いの経緯

### 決まっていること

- **会場の端末は鍵を持たない。14c(鍵の入力と保存)は作らない。14 の `VENUE KEY` 欄は、読み込んだ配信パックの実際の状態を出す。**
  委任用の鍵(spec 122 の delegate mode)は v2 以降の選択肢のまま。
  出典: DECISIONS.md 2026-09-27「会場の端末は鍵を持たない(#432 を維持)。14c の鍵入力画面は作らず、14 の VENUE KEY 欄は読み込んだ配信パックの実際の状態を出す」
  (`/Users/ko/agent-workspace/projects/beid/DECISIONS.md:2135-2138`、決定者: ユーザー)。
- 本書はこの決定の中で、`VENUE KEY` 欄に**何を・どの状態で**出すかだけを設計する。鍵の保存、Keychain / Keystore の項目、署名の経路は設計しない。

### 食い違い(なぜ 2 度決め直したか)

| 出典 | 言っていること |
|---|---|
| beid#702 本文(https://github.com/thegreeting/beid/issues/702) | 「主催者から受け取った 64 桁 16 進の鍵を端末に保存し(『この端末から出ない』)、署名付きの配信に使う」 |
| DECISIONS.md 2026-09-27 (3)(`DECISIONS.md:2129`) | 「主催者から受け取った鍵を端末に保存し、署名付きの配信に使う」。ただし同 `:2130` (b) で「鍵の用途と、それで何に署名するかは既存の署名付き配信(パック)の仕組みとの関係を一次資料で確かめ」と、確認を条件にしている。**「64 桁 16 進」という語はこの項目には無い**(それは #702 本文と Figma 14c の語) |
| beid#432 Maintainer decision 2026-09-10(https://github.com/thegreeting/beid/issues/432#issuecomment-5613854499 と本文「決まったこと」) | 「会場発信ファイル = 署名済み authority-direct v2 封筒の束 … **鍵は入らない**」「署名者 = 登録 Web ページで生まれるイベント専用の使い捨て鍵 … 両 tx の確定と束の保存を確認してから破棄する」。本文: 「主催者も会場スタッフも鍵を保持しない」「委任モード(spec 122 delegate)… は v2 以降」 |
| Barnard v0.9.2 `tools/venue-envelope-producer/README.md:42-43` | "`delegationCert` is not exposed here: this tool only produces authority-direct envelopes (empty cert), per beid#432's design -- the venue device holds no key, so there is nothing to delegate to." |
| Figma 14c `210:140`(実測) | 見出し `Venue key`、本文 `Needed to serve signed proofs. Paste the key the event organizer gave you. It never leaves this phone.`、入力欄のプレースホルダ `vk_…`、注記 `64 HEX CHARACTERS · CASE-INSENSITIVE`、状態 `KEY · NOT CONFIGURED` / `FOR EVENT · —`、`REMOVE KEY`、主ボタン `Save key` |

#432 の決定は DECISIONS.md に記録されておらず issue にだけあった(`DECISIONS.md:2137`)ため、09-27 (3) は知らずにそれを覆す形になっていた。

**64 桁 16 進(= 32 バイト)が Barnard 0.9.2 の何に当たるか**(Figma の鍵を実装できない理由の裏付け):

| 32 バイトの値 | 出典 | 秘密か |
|---|---|---|
| 署名用秘密鍵(secp256k1 スカラー) | `BarnardCoreSigning.swift:166-178`(`privateKey.count == 32`)、`tools/venue-envelope-producer/README.md:28`(`signingPrivateKeyHex`: "32 bytes, hex") | **秘密**。イベントの authority key そのもの。#432 に反する |
| eventId | `BarnardB005EnvelopeV2.swift:468-472`(keccak256 の出力) | 公開 |
| パックのダイジェスト | `shared/.../venue/VenueBundle.kt:22`(`bundleDigest: ByteString32`) | 公開 |
| nonce | `BarnardB005EnvelopeV2.swift:382`(`nonce.count == 32`) | 公開(封筒に載る) |

authority の**公開鍵**は圧縮形式 33 バイト(66 桁)であり、64 桁ではない(`BarnardB005EnvelopeV2.swift:136`, `:384`)。
Figma の本文「It never leaves this phone」は秘密を示すので、Figma が意図したのは表の 1 行目か、spec 122 の delegate 鍵
(spec 122 `specs/122-b005-v2-signed-envelope/spec.md:52-53`, `:124-128`。delegate の秘密鍵も同じ 32 バイトのスカラー)の
どちらかと読める。**デザイナーが何を意図したかは確定していない(not established)。** 確定させるにはデザイナーへの確認が要るが、
2026-09-27 の決定により 14c は作らないので、確認の必要は無い。

なお delegate mode について: Barnard 0.9.2 の検証器は証明書付き封筒を受け付ける
(`BarnardB005EnvelopeV2.swift:515-531`: cert の `eventId` 一致・`roles == 1`・ENIN 範囲・authority key による cert 署名を確認し、
封筒の署名者を `delegateKey` に固定)。一方、**DelegationCert を発行・符号化する public API は v0.9.2 の Swift / Android パッケージに無い**
(`git grep -n -i -E 'func .*(delegat|issueCert|encodeCert|makeCert)' v0.9.2 -- packages/swift packages/android` はテスト 2 件のみ)。
v2 以降で delegate mode を採るなら、Barnard 側の cert 発行 API(または parallax 側の ceremony)が先に要る(KMP-002: beid で再実装しない)。

### 14c のフレームと `vk_…` の扱い

- **14c は作らない。** 14 から 14c へのナビゲーションも作らない。Figma 14(`208:123`)の `VENUE KEY` 欄には `→` も行ボタンも無く
  (実測: 子ノードは `VENUE KEY` / `STATUS` / `NOT CONFIGURED` / `EVENT` / `ETH Tokyo 2026` のテキストと罫線だけ)、
  14 の画面上に 14c への入口は描かれていない。Figma のプロトタイプ接続(画面遷移の矢印)は `get_metadata` に出ないため、
  **14 → 14c のプロトタイプ遷移が定義されているかは確認していない(not established)**。どちらでも本設計は変わらない。
- **`vk_…` は 14c の入力欄のプレースホルダであり、14 には出てこない**(14 の実測テキストに `vk_` は無い)。
  `vk_` という接頭辞は beid(`git grep -I 'vk_' HEAD` 0 件)にも Barnard v0.9.2(`git grep -I 'vk_' v0.9.2` 0 件)にも無く、
  由来は確定していない。**14c を作らない以上、`vk_` による伏せ字表示はどこにも残らない。** `VENUE KEY` 欄は鍵を表示しない。
  パックの値も伏せ字にしない(伏せる理由の秘密がそもそも無い)。
- Figma 14 の `EVENT · ETH Tokyo 2026` と `STATUS · NOT CONFIGURED` が同時に描かれている点は、フレーム自体が 2 つの状態を
  混ぜた見本である(設定なしなのにイベント名がある)。本設計は状態ごとに分ける(§6)。

---

## 1. 何を保存するか

**新しく保存する物は無い。** `VENUE KEY` 欄は、既に保存されている配信パックの記録と、既存のメモリ上の状態からだけ作る。

既存の保存物(変更しない):

| 項目 | 型 | 出典 |
|---|---|---|
| `bundleBytes` | `Data`(パック本体、公開) | `ios/Beid/Persistence/VenuePublicArtifactStore.swift:17` |
| `handoffBytes` | `Data`(リンクの断片から得た `VenueHandoffV1`、公開) | `:18` |
| `sourceDescription` | `String`(取得元の説明。「再取得に使わず、信頼もしない」) | `:19-21` |
| `storedAt` | `Date` | `:22` |

この記録は**意図して公開バイトしか持たない**。取り込みの受領、配信許可、表示名、ダイジェストの判定、期限は保存しない。
保存すると前回の検証で配信を再開できてしまい、期限切れに気づけないため(`VenuePublicArtifactStore.swift:9-15`)。
記録は 1 件だけ(`:33-35`)。

**本設計はこの規則を守る。** つまり `VENUE KEY` 欄のために、表示名・eventId の検証結果・有効期間・「確認済み」の判定を
新たに保存しない。保存した判定を 14 に出すことは、上の規則が防いでいる事故(古い判定を今の状態として見せる)と同じ形になる。

### 保持と削除(現状の事実)

- 保存先はアプリの Documents 下の `venue-public-artifact.json`(`VenuePublicArtifactStore.swift:58-61`)。書き込みは atomic(`:96`)、
  読めないファイルは隔離する(`:79-85`、`CorruptStoreQuarantine`)。
- **`VenuePublicArtifactStore.clear()`(`:68-71`)を呼ぶ本番コードは無い**(`git grep -n '\.clear()' -- ios/Beid` で、該当は
  `WalletHintStore` と `selfProofCheckpointStore` だけ)。新しいパックを読み込むと上書きされ(`:63-66`)、それ以外では残る。
  「Stop broadcasting」(`VenueSignedServingViewModel.swift:561-572`)も記録を消さない。
- 本設計は保持と削除の挙動を変えない。削除の操作を 14 に足すかどうかは Open decision O4。

---

## 2. どこに

- **iOS**: 既存の `VenuePublicArtifactStore`(上記)。Keychain の項目は**足さない**。beid の Keychain への書き込みは
  現在 `ios/Beid/Sensing/BeidKeychainKeyStorage.swift:73` の 1 箇所だけ(`git grep -n -c SecItemAdd -- ios/Beid` = 1)で、
  本設計の後も 1 のまま(§7 T5)。
- **Android**: 14 Organizer tools に当たる画面も `VENUE KEY` 欄も無い。詳細は §5。Keystore の項目も足さない。
- **`shared/`**: 触らない。使う値はすべて iOS の native 層に既にある(`VenuePublicArtifactStore` の公開プロパティと、
  `VenueSignedServingViewModel` の公開状態)。パックの解読(`decodeVenueBundleHex`)を 14 で新たに呼ぶことも**しない**
  (§6 と O3 の理由)。したがって Swift Export の生成名(`ExportedKotlinPackages.org.levarac.parallax.venue.*`)は増えも変わりもしない。
  `docs/kmp-shared-foundation.md` §1(`:28-45`)の分類でいえば、これは「保存場所・UI」の native 側の表示であり、
  両 OS が同じ答えを出すべき判断(A/B/C のいずれか)を新たに作らない。

---

## 3. 端末外に出ない / 送信・署名の内容を変えない

本設計は**読むだけ**である。

| 経路 | 本設計の後 | 根拠 |
|---|---|---|
| 送信ペイロード(ウィンドウ報告) | 変わらない。`VENUE KEY` 欄のコードは報告・台帳・署名の型に触れない | 触る型は `VenuePublicArtifactStore` と `VenueSignedServingViewModel` と 14 の View だけ(§6) |
| 署名するバイト列 | 変わらない。beid は会場封筒に署名しない(署名済み container を渡すだけ)。Barnard も署名しない: `configureOwnEventInfoEnvelopeV2` は "The SDK does not sign, re-encode, or re-verify it"(`packages/swift/barnard/Sources/Barnard/BarnardEngine.swift:662-666`) | 14 は radio にも verifier にも触れない(§7 T2) |
| 電波に乗るバイト列 | 変わらない。電波に乗るのは 14b で得た permit の `container` だけ(`VenueBundleVerification.swift:935`, `VenueSignedServingViewModel.swift:697-702`) | 同上 |
| 公開データ・チェーン | 変わらない | 同上 |
| ネットワーク | **14 を開いても通信しない**。registry の読み取り(`VenueBundleVerification.swift:774-797`)は 14b の取り込み・評価の中でだけ起きる | §7 T2 で acquisition / verifier の呼び出し 0 回を固定 |
| ログ | 変わらない。venue 系の 7 ファイル(`OrganizerToolsView.swift` / `VenueSignedServingView.swift` / `VenueSignedServingViewModel.swift` / `VenueBundleVerification.swift` / `VenueSignedContainerBroadcasting.swift` / `VenueArtifactAcquisition.swift` / `VenuePublicArtifactStore.swift`)に `print(` / `os_log` / `Logger(` / `NSLog` は 0 件(`git grep` 実測)。Barnard の `own_envelope_v2` デバッグイベントは `supplied` とバイト数だけ(`BarnardEngine.swift:679`, `:691-693`) | 本設計はログ呼び出しを足さない |
| 解析・クラッシュ収集 | beid に解析 SDK は無い(`git grep -i -E 'analytics|telemetry|crashlytics|firebase' -- ios/Beid` 0 件) | — |
| ペーストボード | 14 は `UIPasteboard` を使わない。14b の Paste / Copy(`VenueSignedServingView.swift:138`, `:310`)は変えない | — |
| バックアップ | 保存場所も属性も変えない(`VenuePublicArtifactStore.swift:58-61`)。中身は公開バイトだけ | — |
| 保存 | 新しい書き込みをしない。14 を表示しても `venue-public-artifact.json` のバイト列は変わらない | §7 T3 |

秘密の値が 1 つも登場しないので、「鍵がログや送信に出ない」ことを証明する対象そのものが無い。代わりに固定するのは
**(1) 14 が読むだけであること、(2) 保存記録が公開バイト以外を持たないこと、(3) Keychain の書き込み箇所が増えないこと**(§7)。
手本は beid#652 の `ios/BeidTests/SignalStrengthNeverRecordedTests.swift` の二本立て(`:30-43`: 振る舞いとして
シリアライズ後のバイト列を探す / 構造としてコーデックが出すキー名を固定する)と、「空だから緑」を防ぐ正の assertion を
必ず対にする規則(`:45-53`)。

---

## 4. 既存の記録

- 移行しない。推測で埋めない。
- 既存の `venue-public-artifact.json` はそのまま読む(形式を変えないので移行が要らない)。
- パックを一度も読み込んでいない端末は「保存済みのパックなし」を出す(§6 状態 S0)。

---

## 5. 両 OS

- **iOS**: 本 issue で実装する。
- **Android**: 本 issue では触らない。理由: Android には 14 Organizer tools に当たる画面が無く、Flat 2b は iOS 先行
  (DECISIONS.md 2026-09-22 `:1675-1676`、#647 本文「対象外: Android。Venue の画面は iOS にしかない(#460)」、PR #679「Both-OS」節)。
  - ただし **Android にも署名付きパックの取り込みと配信は既にある**(PR #622、2026-09-22 に main へマージ、`Refs #460, Refs #603`):
    `android/app/src/main/kotlin/org/levarac/beid/venue/VenueActivity.kt`、Account からの入口
    `android/app/src/main/kotlin/org/levarac/beid/navigation/AppNavHost.kt:141`。
    その `VenuePack`(`VenuePorts.kt:7-13`)はメモリ上だけで、venue パッケージにファイル保存は無い
    (`git grep -n -i -E 'SharedPreferences|filesDir|dataStore|File\(' -- android/app/src/main/kotlin/org/levarac/beid/venue` 0 件)。
    したがって Android で同じ欄を作るには、まず保存済みパックという状態そのものが要る。
  - 追跡先: beid#460(OPEN、マイルストーン「v1.30 Android 版」、`gh issue view 460` 実測)。本設計の §6 の状態表は、
    Android で同じ欄を作るときの仕様としてそのまま使える。
- **shared**: 触らない(§2)。

---

## 6. UI — `VENUE KEY` 欄に出す物

### 前提: 14 が見える時点で、配信は既に止まっている

- 14b(`VenueSignedServingView`)は、画面を離れるとき必ず `viewModel.endSession()` を呼ぶ(`VenueSignedServingView.swift:89-96`。
  コメント: "A real route departure always ends the session and clears the radio.")。`endSession()` は `stop()` を呼び
  (`VenueSignedServingViewModel.swift:581-584`)、`stop()` は電波を止め、進行中の処理と選択を捨て、`status = .idle` にする(`:561-572`)。
- 14b は 14 から push される(`OrganizerToolsView.swift:75-78`)ので、**14 が画面に出ているときは 14b が画面から外れており、
  配信は止まっている。** 検証済みの事実(eventId と定義 sequence とダイジェスト: 取り込みの受領 `VenueBundleVerification.swift:672-679`、
  表示名と期限: permit `:929-947`)は、そのとき既にどこにも残っていない(保存しない規則は §1)。
- **したがって、14 で「確認済み」「配信中」「スライス N を配信中」「期限切れ」「検証に失敗」を正しく出す方法は無い。** それらは
  14b にしか存在しない状態で、14b が既存の文言で出している(`VenueSignedServingView.swift:412-424`, `:524-619`)。
  14 がそれを出すには (a) 判定を保存する(§1 の規則に反する)、(b) 14 を開くたびに registry を読んで再検証する(通信が増え、
  14b の処理を二重に持つ。結果も表示した瞬間から古くなる)、(c) 配信の寿命を 14 まで延ばす(#531 の安全策「画面を離れたら電波を止める」を
  変える)のどれかが要る。いずれも本 issue の範囲外として採らない(O2)。
- この読み方はコードを読んで得たもので、**「14 が見えている間に `status == .serving` にならない」ことを直接確かめたテストは無い**
  (`FlatScreenshotTourD.swift:98-105` は初期状態で `Not broadcasting` を確かめるだけ)。§7 T4 で固定する。

### 14 が実際に知っている事実

| 事実 | 取り方 | 信頼の種類 |
|---|---|---|
| 保存済みパックがあるか | `VenuePublicArtifactStore.record != nil`。VM は `storedSourceDescription`(`VenueSignedServingViewModel.swift:132`, 初期化 `:228`, 更新 `:420`, `:502`, `:547`)で同じことを公開している | 端末上の実測 |
| どこから来たか | `record.sourceDescription`(`VenuePublicArtifactStore.swift:19-21`)。リンクからの取り込みでは `"link, bundle from <host>"`(`VenueSignedServingViewModel.swift:497`)。この端末が実際にそのホストから取得した事実であって、パックの中身の正しさではない | 端末上の実測(中身は未検証) |
| いつ保存したか | `record.storedAt`(`VenuePublicArtifactStore.swift:22`, 書き込み `VenueSignedServingViewModel.swift:418`, `:500`) | 端末上の実測 |
| 保存に失敗したか(14g) | `store.persistenceWriteFailure != nil || store.isPersistenceSuspended`。VM は `hasUnsavedArtifact`(`VenueSignedServingViewModel.swift:182`, `:419`, `:501`)として同じ式を公開 | 端末上の実測 |
| 保存ファイルが読めず隔離されたか | `store.quarantinedFileURL != nil`(`VenuePublicArtifactStore.swift:43`, `:84`) | 端末上の実測 |

出さない物と理由:

| 候補 | 出さない理由 |
|---|---|
| 表示名(Figma の `EVENT · ETH Tokyo 2026`) | 表示名は SDK が検証した permit にしか無い(`VenueBundleVerification.swift:131-133`, `:157`, `VenueSignedServingViewModel.swift:73-77`)。14 の時点では存在しない。保存も禁止(`VenuePublicArtifactStore.swift:9-15`) |
| eventId | 保存バイトを解読すれば取れるが、それは**未検証の構造**である(`shared/.../venue/VenueBundle.kt:7-11`: "Decoding does not authenticate an artifact")。検証済みの eventId は受領と permit にしか無い。O3 |
| 有効期間 `validFromEnin` / `validThroughEnin` / スライスごとの `relayExpiresAtEnin` | 検証結果 `BarnardB005VerifiedEnvelope`(Barnard `BarnardB005EnvelopeV2.swift:42-60`)は 14b の評価の中にしか無く、beid はそれを受領にも permit にも持ち出していない(permit が持つのは `currentEnin` と `[startAt, stopAt)` だけ、`VenueBundleVerification.swift:154-170`) |
| 「スライス N / M」 | shared の `VenueCurrentLease.selectedEnvelopeIndex`(`shared/.../venue/VenueCurrentLease.kt:46-50`)は permit に写されない(`VenueBundleVerification.swift:929-947`)。14 の時点では存在しない |
| authority 公開鍵 | beid はどの型にも持ち出していない(検証結果が持つのも `keySetDigest` だけ、Barnard `BarnardB005EnvelopeV2.swift:46`)。しかも「VENUE KEY」の欄に公開鍵を出すと、鍵を預かっているという誤読を招く |
| ダイジェスト | 受領と permit にだけある(`VenueBundleVerification.swift:125-129`)。保存バイトからの解読値は未検証 |
| 配信中 / 確認済み | 上の前提により、14 の時点では常に偽 |

### 状態ごとの表示

欄の構成は Figma 14 の形(見出し + `STATUS` 行 + 値の行)に合わせる。見出しの語は O1。
行ごとの「無し」表示はしない(値が無い行は出さない)。

| 状態 | 条件(優先順) | `STATUS` の値 | 追加の行 | 注記 |
|---|---|---|---|---|
| S3 保存できなかった(14g) | `record != nil` かつ(`persistenceWriteFailure != nil` または `isPersistenceSuspended`) | `Not saved`(**既存**、`VenueSignedServingView.swift:55`、xcstrings `:2110`) | `Source` · `<sourceDescription>` | `This pack could not be saved. It stays on this device only until the app closes.`(**既存**、`VenueSignedServingView.swift:56`) |
| S2 保存済み | `record != nil` | `Saved on this device`(**新規**) | `Source` · `<sourceDescription>`(見出しは**既存**の未使用キー `Source`、xcstrings `:1823-1825`、コメント "Section header for where the venue bundle is fetched from.")/ `Saved` · `<storedAt の日時>`(**新規**の見出し。値は `Date.formatted`) | `A saved pack is checked again every time it is loaded.`(**既存**の未使用キー、xcstrings `:2077`) |
| S1 保存ファイルが読めなかった | `record == nil` かつ(`quarantinedFileURL != nil` または `isPersistenceSuspended`) | `Could not read`(**新規**) | なし | `This pack could not be read.`(**既存**、`VenueSignedServingView.swift:527`、xcstrings `:2147`) |
| S0 保存済みパックなし | 上のどれでもない | `No saved pack`(**新規**) | なし | なし |

S1 に `isPersistenceSuspended` を含めるのは、`CorruptStoreQuarantine.resolve`(`ios/Beid/Persistence/CorruptStoreQuarantine.swift:67-94`)が `.unpreserved`(書き込み停止あり・`quarantinedFileURL == nil`)を返すのが「DecodingError 以外の読み取り失敗」と「壊れたファイルを移動できなかった」の 2 つだけで、どちらもディスク上に読めないファイルが残っているためである(ここで「保存済みパックなし」と出すと事実に反する)。

補足:

- 優先順は S3 → S2 → S1 → S0。S3 を S2 より先に判定するのは、保存に失敗したときも `record` はメモリ上にある
  (`VenuePublicArtifactStore.swift:63-66` は代入してから `save()` する)ため。逆にすると「保存済み」と偽って出す。
- **「配信中か」は `Venue broadcast` 行の既存の状態(`OrganizerToolsView.swift:50-52`, `:83-86`)が受け持ち、`VENUE KEY` 欄では繰り返さない。**
- 14b 側の状態(取得中・確認中・配信を依頼した・時間前・期限切れ・拒否・電波停止)と既存の 30 種の文言は変えない(#647 の規則)。
  S0〜S3 の文言はそれらと衝突しない。
- `Asked to broadcast. The system has not confirmed it is on air.` を「発信中」と言い換えない規則(#647 本文)には触れない。
  14 は発信について何も言わない。
- **この欄は操作を持たない。** 押しても何も起きない(Figma 14 にも `→` が無い)。14b への入口は `Venue broadcast` 行の 1 つのまま
  (#597、`OrganizerToolsView.swift:6-8`)。
- **削除**: 本設計では 14 に削除の操作を置かない(O4)。したがって「削除したとき配信中の電波はどうなるか」は起きない
  (14 が見えている時点で配信は止まっている。上の前提)。O4 で削除を足す場合も、その時点で電波は止まっているので、
  消すのは保存ファイルだけになる。
- 新規の文言は 4 つ(`Saved on this device` / `Could not read` / `No saved pack` / `Saved`)と、O1 で決めた見出し 1 つ。
  新規の文言は `Localizable.xcstrings` に英語で足す(DECISIONS.md 2026-09-22 `:1686`「日本語対応は不要」)。

### 実装の形(Implemented)

- 判定は純粋関数 1 つに置く: 入力 `(record: VenuePublicArtifactRecord?, persistenceFailed: Bool, persistenceSuspended: Bool, quarantined: Bool)`、
  出力 `enum SavedPackRowState { case none, unreadable, saved(source: String, storedAt: Date), notSaved(source: String) }`。
  View はこの enum を描くだけにする(テストを View から切り離すため)。
- 読み取り元: `OrganizerToolsView` が `VenuePublicArtifactStore` を自分の `@StateObject` として持ち、それを VM の初期化に渡す
  (現在は VM の初期化引数の中で生成している、`OrganizerToolsView.swift:10-16`。VM は `store` を private に持つ、
  `VenueSignedServingViewModel.swift:158`)。`record` と `persistenceWriteFailure` は `@Published`(`VenuePublicArtifactStore.swift:38-39`)。
  `quarantinedFileURL` と `persistenceSuspensionReason` は `@Published` ではないが、`load()`(初期化時に 1 回、`:53-56`)でしか
  変わらないので、欄の再描画には `record` の変化で足りる。
- 14b と VM と verifier と store の書き込み経路は変えない。

---

## 7. テスト計画と変異の対象

実行は AGENTS.md の規則どおり、変更したファイルを覆う全スイートを `scripts/run_local_tests.py ios --erase-simulator` で回す
(UDID 指定、消去した Simulator)。

| # | テスト | 何を固定するか | 空で緑にならないための正の assertion |
|---|---|---|---|
| T1 | `SavedPackRowStateTests`(新規、BeidTests) | S0〜S3 の 4 状態と優先順。特に「`record` があり書き込み失敗 → `notSaved`」「`record` なし・隔離あり → `unreadable`」 | 各ケースで入力の `record` が実在すること(S2/S3 は `source` と `storedAt` が入力と一致すること)を確かめる |
| T2 | `OrganizerToolsReadsOnlyTests`(新規、BeidTests) | 保存済み記録がある状態で 14 の行状態を作っても、`ScriptedVenuePorts`(verifier と broadcasting を兼ねる、呼び出し記録は `calls`、`ios/BeidTests/Support/ScriptedVenuePorts.swift:12`, `:44`)に import / evaluate / install の記録が 0 件、`StubVenueArtifactAcquisition` の `requestedSources`(`ios/BeidTests/Support/VenueSignedServingTestDoubles.swift:63`, `:80`)が 0 件であること。**通信も電波も起きない** | 同じ doubles で 14b の `restoreFromStorage()` を呼べば各 1 回以上になることを同じテスト内で確かめ、「数え方が壊れていて 0」を除く |
| T3 | 同上 | 14 の行状態を作る前後で `venue-public-artifact.json` のバイト列が同一(**新しい書き込みが無い**) | 前のファイルが存在し、空でないこと |
| T4 | `VenueSignedServingViewModelTests` に追加 | 配信中(`.serving`)に `endSession()` を呼ぶと `status == .idle`・`servingEventIdHex == nil`・broadcasting の `clearAndStop` が呼ばれる。§6 の前提「14 が見えるとき配信は止まっている」の VM 側 | 呼ぶ前に `.serving` であることを確かめる |
| T5 | 既存 `testStoredRecordHoldsOnlyPublicBytes`(`VenueSignedServingViewModelTests.swift:1304-1322`)を拡張 | `VenuePublicArtifactRecord` をエンコードした JSON のキー集合が**ちょうど** `{bundleBytes, handoffBytes, sourceDescription, storedAt}` である(`SignalStrengthNeverRecordedTests` の構造テストと同じ型)。表示名・判定・期限・鍵のフィールドが足された日に赤になる | キー集合が空でないこと、4 つすべてがあること |
| T6 | `FlatScreenshotTourD.testShot_14_OrganizerTools`(`ios/BeidUITests/FlatScreenshotTourD.swift:98-120`)を拡張 | 起動ごとに隔離したストア(DEBUG かつ `-beid-ui-test` のとき `OrganizerToolsObjects.storeURL(arguments:)` が一時ディレクトリに新しいファイルを 1 起動に 1 つ与える)で、欄の見出し(O1 の語)と `No saved pack` が出る。Simulator の消去にもテストの順序にも依存しない。14 に `TextField` が無く、`Venue key` / `Save key` / `REMOVE KEY` の要素が無い(14c を作っていない) | 見出しの要素が存在すること |
| T7 | 同ツアーに既存の DEBUG フィクスチャ(`-beid-venue-frame`、`VenueSignedServingView.swift:444-455` と同じ方式)で S2 / S3 を 1 枚ずつ追加 | Figma 14 との並置比較用(DECISIONS.md 2026-09-26 `:2076`) | 各フレームで `STATUS` の値の要素が存在すること |

Keychain の書き込み箇所が増えないこと: `git grep -n -c SecItemAdd -- ios/Beid` が 1 のままであることを、実装 PR の検証欄に記録する
(CI の自動チェックにはしない。これは本 issue 1 回きりの確認)。

### 変異の対象

- `shared/` を触らないので `scripts/mutation_check.py`(Kotlin 専用)は対象外。
- Swift 側は手で変異させ、それぞれ指定のテストが赤になることを RED の証拠として PR に記録する:
  1. 優先順を入れ替え S2 を S3 より先に判定する → T1 が赤
  2. S1 の分岐(`quarantined || persistenceSuspended`)を消す → T1 が赤
  3. `record == nil` でも `saved` を返す → T1 が赤
  4. 14 の行状態の生成で `restoreFromStorage()` を呼ぶ(再検証を足す)→ T2 が赤
  5. 14 の生成で `store.store(...)` を呼ぶ → T3 が赤
  6. `VenuePublicArtifactRecord` に `displayName: String?` を足す → T5 が赤
  7. `endSession()` から `stop()` を外す → T4 が赤
  8. S1 の行から `|| persistenceSuspended` を外す → T1 が赤(`resolve(nil, false, true, false)` と、実ストアの `.unpreserved` の場合)
  9. `-beid-ui-test` のもとで `OrganizerToolsObjects.storeURL(arguments:)` が `nil` を返す(既定の `Documents/venue-public-artifact.json` に戻る)→ 先行する TourD のテスト(14b やリンク/パックの結果)がパックを保存していると T6 が赤(PM が観測した順序依存の失敗)、`testOrganizerStoreURLIsIsolatedOnlyUnderUITest` が赤

---

## Open decisions

### O1 — 見出しの語。Figma は `VENUE KEY` だが、中身は鍵ではなくパック — **DECIDED: `Saved pack`**

- **A. `Saved pack`(推奨・DECIDED)** — 中身(この端末に保存したパック)そのもの。14b の語「pack」(#647 本文「`bundle` ではなく `pack`」)と揃う。新規の文言。
- B. `Venue pack` — 同じく正しいが、「会場のパック」は保存の有無を言わない。新規。
- C. `VENUE KEY` のまま — Figma に一致するが、鍵を預かっていると読める。2026-09-27 の決定の理由(鍵を持たない)と逆向きの印象を与える。

推奨理由: 欄が示すのは「この端末に保存されているか」なので、その語を見出しに置く。

**Decided: `Saved pack`, confirmed by maintainer decision on 2026-09-27** — replaces Figma's
`VENUE KEY`, in line with the decision (#432) that the venue device holds no key.

**Implementation: A.** `OrganizerToolsView.swift:230`'s heading is the literal `"Saved pack"`.
`VENUE KEY` survives nowhere as displayed text — the one match is a code comment at
`OrganizerToolsView.swift:224` ("Figma 14's `VENUE KEY` block", naming Figma's own label for the
frame), not a user-visible string (`git grep -n 'VENUE KEY' -- ios/Beid` returns 1 hit, the same
comment). The implementation matches the maintainer decision; no UI string change is needed.

### O2 — 14 で検証済みの事実(表示名・eventId・期限)を出すか

- **A. 出さない。14b で出す(推奨)** — §6 の前提どおり、14 の時点で検証済みの事実は存在しない。
- B. 14 を開くたびに取り込みと評価をやり直し(配信はしない)、結果を出す — registry への通信が 14 を開くたびに起き、14b の処理を二重に持つ。出した瞬間から古くなる。
- C. 配信の寿命を 14 まで延ばす — #531 の「画面を離れたら電波を止める」安全策を変える。本 issue の範囲を越える。

**Implementation: A.** `OrganizerToolsView.swift`'s `savedPackSection` / `SavedPackRowState` draw
only `source` (`sourceDescription`) and `storedAt`. There is no code that reads or displays a
display name, eventId, or validity window (`grep -n 'displayName\|eventId\|validFrom\|validThrough'
ios/Beid/Views/OrganizerToolsView.swift` returns 0 hits). 14b (`VenueSignedServingView`) is
unchanged.

### O3 — 保存バイトを解読して、未検証の eventId を「パックが名乗るイベント」として出すか

- **A. 出さない(推奨)** — `VenueBundle.kt:7-11` のとおり解読は認証ではない。PM の指示「信頼できる値・測った値だけを出す」に従う。
- B. 「未検証」と明記して短い eventId を出す — 前例として 14b はリンクが名乗る eventId を検証前に `Event ID` 行へ出している(`VenueSignedServingViewModel.swift:134-142`, `VenueSignedServingView.swift:237-242`)。ただしそれはリンクを貼った直後の、打ち間違いに気づかせる目的の表示で、14 の常設欄とは目的が違う。B を採るなら shared の解読を 14 から新たに呼ぶことになる。

**Implementation: A.** `OrganizerToolsView.swift` has no call to `decodeVenueBundleHex`
(`git grep -n decodeVenueBundleHex -- ios/Beid/Views/OrganizerToolsView.swift` returns 0 hits). No
code path decodes the stored bytes on 14.

### O4 — 14 に「保存済みパックを消す」操作を置くか

- **A. 置かない(推奨)** — 現在も削除の操作は無い(§1: `clear()` の本番呼び出し 0 件)。Flat 2b で機能を増やさない方針(DECISIONS.md 2026-09-22 `:1687`「再デザインで新機能を増やさない」)。
- B. 置く(Figma 14c の `REMOVE KEY` に当たる物を 14 に) — 呼ぶのは `VenuePublicArtifactStore.clear()` だけで、14 の時点で電波は止まっている。破壊的操作なので確認ダイアログの有無も決める必要がある。別 issue にするのが妥当。

**Implementation: A.** `OrganizerToolsView.swift` has no call to `.clear()`. 14 only reads; there
is no delete action or button (`savedPackSection` has no row with an action attached).
`VenuePublicArtifactStore.clear()` still has 0 production callers, as §1 states.

### O5 — Figma 14 の `Venue device`(v1)行

- 本 issue の範囲外。#597 で外し、#679 でも出していない(PR #679「Figma との差」)。デザイナーへの質問は #642 の Q6
  (`docs/decisions/issue-642-account-inventory.md:442-455`)で既に上がっている。本設計はこの行について何も変えない。

**Implementation: still out of scope, untouched.** `OrganizerToolsView.swift` has no `Venue
device` UI row. The one match is a code comment at `:121` ("#597 withdrew the unsigned Venue
device entrance", recording that #597 already removed it), not user-visible text (`git grep -n
'Venue device' -- ios/Beid/Views/OrganizerToolsView.swift` returns 1 hit, the same comment).
#642 Q6's question remains unanswered.
