# WalletConnect relay 依存の扱い方（調査結果と段階的対応方針、ドラフト v0.2）

> **位置づけ**: これは AI エージェント（Claude Code）が Ken との調査セッション（GPT Pro deep research × 2ラウンド、一次情報の直接確認込み、fable-oracleによる監査済み）をもとに作成した叩き台です。決定ではなく検討材料です。技術的な結論部分は一次情報（各SDK公式ドキュメント・ソースコード・spec）で裏取り済み。beid の現行実装コードとの突き合わせも、fable-oracleがローカルclone（origin/main @ 0292314、PR#32まで反映済み）を直接確認して裏取り済み（下記1節参照）。ネットワーク障害時に投稿前の最終鮮度チェックのみ未実施（下記「未検証事項」参照）。

## 1. 背景・きっかけ

beid は wallet 接続に WalletConnect v2（reown-swift 2.3.0）を採用しており、`main`には実接続（reown-swift 2.3.0 Sign統合、PR#27 "feat/walletconnect-integrate"、commit 94df621、2026-07-11 22:25 merge）が入っている。relay（メッセージ中継）は Reown Cloud（Reown社が運営）に依存する。この依存についてコスト面の懸念から調査を開始したが、調べた結果コストは問題ではなく（後述）、論点は「Reown という単一事業者への依存をどこまで・どうやって減らせるか」という設計判断に絞られた。

（本ドラフト作成中にGitHub接続障害が発生し一時的に merge 状況を直接確認できない期間があったが、fable-oracleがローカルclone上で `ReownWalletConnectClient.swift` 等の実在と `WalletConnectStub` の不在を直接確認し、裏取り済み。）

## 2. 調査した選択肢と結論

### 2.1 コストは問題ではない

Reown Cloud の Free tier（$0、月間アクティブユーザー500人・RPC呼び出し250万回まで）で、beid の現状の利用規模には当面十分。有料化するのは月間アクティブ利用者が500人を超えてから。

### 2.2 自前で relay を立てるのは非現実的

WalletConnect公式の旧relay実装（`WalletConnect/relay`）は2024-05-28にarchive済み。README に「production利用は非推奨」「セルフホストは現状サポート対象外」と明記されている。ゼロから自作する場合、常時稼働WebSocket・JWT認証・永続メールボックス・再送/冪等性・水平スケーリング・DDoS対策・多リージョン可用性・24時間監視が最低要件になり、個人開発／小規模チームの手に余る。

### 2.3 WalletConnect Network のノードオペレーターになる案も、現状は門が閉じている

WalletConnect Network は Service Node / Gateway Node からなる分散ネットワークとして実際に稼働しており、Consensys, Ledger, Kiln, Figment 等20以上の機関クラスの事業者がノードを運用している（Kiln・Figmentはステーキングインフラ専業）。ハードウェア要件自体はNode×2台（各4CPU/8GB RAM）+ Database×1台（8CPU/16GB RAM/200GB SSD）と、Ethereum solo validator を既に運用している Levarac のインフラ経験があれば現実的な規模。しかし**「ノードアクセスは現状まだ許可制で、個人が自由に参加できる段階ではない」**と公式に明記されており、参加にはWalletConnectチームへの直接連絡・交渉が必要（今の参加者は皆、機関クラスの実績ある事業者）。仮に参加できても、beid自身のトラフィックが自分のノード経由になる保証があるかは未確認。

**将来 Phase 3（完全 permissionless）が来れば話は変わる。恒常的なウォッチ項目として、WCNの permissionless onboarding が始まったタイミングでノード運用を再評価する、という trigger をどこかに残しておく（コスト0で置ける監視項目）。**

### 2.4 既存の他の分散ネットワークへの転用は、ウォレット互換性の壁で頓挫する

Waku, Nostr, libp2p, IPFS Pubsub, Ethereum devp2p（Levaracが運用するsolo validatorが繋がっているネットワークそのもの）を含め6候補を評価。技術的に一番近いのは Waku（Relay/Store/Filter/Light Push という、WalletConnectのrelayに近い機能構成を持つ既存の共有ネットワーク）だが、**いずれの候補も「dApp側だけが対応しても、接続先の既存ウォレット（MetaMask, Rainbow等）が同じネットワークを喋らなければ繋がらない」という制約を超えられない**。WalletConnectのPairing URIには `relay-protocol`（通常`irn`）が含まれるが、ウォレットに別ネットワークへ接続させる標準フィールドは存在しない。

Ethereum devp2p（RLPx）については、Levaracが実際に運用しているsolo validatorのネットワークそのものだが、RLPxは事前に合意した通信種別（`eth`, `snap`等のcapability）しか運ばない設計で、任意のアプリメッセージを既存のEthereumノード群が転送してくれるわけではない。「今動いている validator を転用する」という発想は成立しない。

Waku限定であれば、「beidと、Levarac管理下の実験用ウォレットの両方を改修し、暗号化済みWalletConnectメッセージをWaku経由で運べるか検証する」という**独自WalletConnect派生クライアント同士の通信としての研究PoC**は成立するが、これは既製ウォレットとの互換性を諦める前提になる。

### 2.5 SIWE (EIP-4361) は別レイヤーの話

「EOAでログインできればいい」という目的でSign-In with Ethereum (login.xyz / EIP-4361) を検討したが、SIWEは**署名するメッセージの標準フォーマット**であり、ウォレットへの接続方法（トランスポート）は範囲外。モバイルではSIWEも結局WalletConnectを橋渡し役として使う（公式解説で明記）。SIWEの採用自体は無関係ではなく、**beid#33（署名ペイロード設計、wallet鍵をaccount keyとして採用するか）の議論には関係する**——現行の独自スキーマ `AttendanceProof/v1` の代わりに、広く使われる標準フォーマットである EIP-4361 に寄せる／参考にする、という選択肢として。ただし接続経路（relay依存）の解決にはならない。

### 2.6 個別ウォレットSDKへの直結：Coinbase Walletのみ真に relay 不要

9つの主要ウォレットを確認した結果:

| ウォレット | 判定 | 備考 |
|---|---|---|
| **Coinbase Wallet** | 真にrelay不要 | Mobile Wallet Protocol、Universal Link経由の直接通信。公式に「relayサーバー不要」と明記。ただし現行OS/ウォレット版でのPoC検証は必要（公開issueに未解決のものあり） |
| MetaMask | relay不要ではなく別relayへの分散 | MetaMask Connect / iOS SDK は Reownのrelayは経由しないが、MetaMask自身の「deeplink relay」を使う。**目的は relay除去でなく Reown からのベンダー分散** |
| Trust Wallet / Rainbow / imToken / Argent | 直結SDKなし | 公式の外部dApp接続方法はいずれもWalletConnect（RainbowはRainbowKit経由も同様） |
| OKX Wallet | 限定的 | 接続経路はあるが本格的なSwift/Kotlin SDKではなく、relay不要かも未確認 |
| Ledger / Safe | 該当なし | 外部dAppから接続する汎用SDKという設計思想自体がない（Ledger Live内でdApp実行、SafeはSafe内でWebアプリ実行というモデル） |

複数ウォレットの直結SDKを束ねて WalletConnect なしで広いカバレッジを得る成熟したアグリゲーターライブラリは存在しない。Dynamic等の「アグリゲーター」も内実は「ブラウザ標準(EIP-6963) + Coinbase固有 + それ以外は全部WalletConnect」という構成。Privy/Dynamic/Web3Auth/Magicも、既存の外部ウォレットとの接続自体はWalletConnectに委ねる認証・セッション管理層であり、relay依存を減らす目的には向かない（むしろSaaS依存が増える）。

### 2.7 現実的な近道：Reown Link Mode（要バージョン確認・実装方式の分岐あり）

対応ウォレット相手には Universal Link 経由で SIWE / セッションリクエストを運び、WebSocket relay を経由しない経路が reown-swift には存在する（`Sign.linkMode` / `dispatchEnvelope(_:)` 等）。ただし**現行の reown-swift 2.3.0 では、Link Mode専用メソッド（`authenticateLinkMode` / `requestLinkMode` / `respondLinkMode`）が `#if DEBUG` で囲われており、Release/App Storeビルドには存在しない**ことを2026-07-12のspike検証で確認済み（`spike/walletconnect-linkmode` ブランチ、非merge）。

GPT Proの調査では、**最新のReown AppKit/iOSでは One-Click Auth + Link Mode が有効化できる**という記載がある。ただしここには**見過ごせない分岐**がある: `main`（spike由来）は「Yttrium / CoinbaseWalletSDK を余分に引き込むのを避けるため」という明示的な理由で、**ReownAppKitではなく低レベルのSign + Pairing APIを意図的に使う実装**になっている——この判断はproject.yml上のコメントに「beidのWalletConnectログイン・AA不採用というチームの裁定に合わないCoinbaseWalletSDK surfaceを避けるため」と明記されており、**単なるspike時点の便宜的選択ではなく、AA不採用という既存のチーム裁定（2026-07-09 MTG決定）に紐づいた意図的な設計判断**である（fable監査で本番mainのproject.yml上に確認済み）。一方GPT ProのLink Mode動作確認は**AppKit限定のスコープ**である可能性が高い。つまり Step 2 の再検証には2通りの結果があり得る:

- (a) 新しいreown-swiftでSign層自体のLink Mode gateが外れる（安価な解決）
- (b) Link ModeはAppKit経由でしか使えず、**AA不採用というチーム裁定に基づく既存の設計判断（AppKitを避ける）を、この場のためだけに覆すかどうかの判断を要する**（単なる技術選択の再検討ではなく、チーム裁定への抵触を伴うためコスト増かつ要相談）

再検証時はこの分岐を明示的に判定すること。(b)の場合は技術判断でなく四條さん・Kenを含めたチーム判断に上げる。

Link Modeを使っても、対応判定（`walletLinkSupportNotProven`）は一度relay経由の往復を経てから行う設計であり、「確立」の段階は依然relay必須。「その後の通信」だけがrelayを経由しなくなる、という限定的な効果である点は変わらない。またLink Mode自体もReownのproject ID / Explorer設定を前提とするため、Reownからの完全独立策ではない。

## 3. 推奨する段階的対応

1. **今すぐ行う（低コストな保険。ただし「無駄にならない」は言い過ぎ——後から実装候補SDKの形が違えば境界の引き直しは要る）**: `WalletConnector` という薄い抽象インターフェースをコード上に導入する。

   ```
   WalletConnector
     connect()
     personalSign(message)
     handleRedirect(url)
     disconnect()
   ```

   SIWEメッセージ生成・nonce管理・domain/URI検査・署名検証はConnectorから分離し、`ReownConnector` / `MetaMaskConnector` / `CoinbaseConnector` のような実装だけを差し替えられる設計にする。**テレメトリは接続方式ごとの成功率・キャンセル率・復帰失敗率だけでなく、(a) WCセッションメタデータからの相手ウォレット識別、(b) relay到達不能かどうかの障害分類、も含めること** —— これがないと、後述Step 3/4の判断基準（MetaMask利用実績・Reown障害実績）自体が測定不能になる。低頻度署名ゆえ、本番で壊れていても発見が遅れる点にも注意。

   なお、beidは近接情報を扱うプライバシー配慮アプリであり、ウォレット識別子や接続結果をテレメトリとして記録する場合、何を・どこに収集するかを一言明記しておく。

2. **次の一手**: reown-swiftを最新版に上げ、One-Click Auth + Link Mode が実際にRelease buildで有効化できるか再検証する（2.3.0時点でDEBUG限定だった点の解消確認）。上記2.7の分岐（Sign層で解消するか、AppKit依存が必要になるか）を明示的に判定する。対応ウォレットはrelayを経由せず、非対応は通常のWalletConnect relayにフォールバックする構成にする。

   参考: WalletConnect (v1) は2023年に強制sunsetされた前例があり、Reownが将来同様の強制移行を行わない保証はない。抽象化レイヤー（Step 1）の意義はこの観点からも補強される。

3. **条件付き**: MetaMaskの利用実績やReown障害の実績データが出てから、到達性確保（Reown障害時の保険）を目的にMetaMask Connectを第二経路として追加するか判断する。relay削減が目的ではないことに注意。

4. **さらに条件付き**: Coinbase Wallet利用率が十分あり、現行iOS/AndroidでのPoCが通った場合のみ、真にrelay不要な経路としてCoinbase Mobile Wallet Protocolを追加する。**Step 2でAppKitを採用した場合、CoinbaseWalletSDKが既にバンドルされているため、このStepのコストは一部相殺される可能性がある**（2.7の分岐(b)を選んだ場合の副次効果）。

5. **追わない**: OKX等を含む多数の個別ウォレットSDKの統合。Privy/Dynamic等relay回避だけを目的にした全面移行。Waku/Nostr等への切り替え（既製ウォレットとの互換性を失うため）。

**進め方の要約**: 1と2に着手し、3と4は利用実績データが出てから条件付きで判断、5は見送る、という整理であって、"1→5を順番に実行する" という意味ではない。

工数感の目安（GPT Pro試算、既存SIWEバックエンドがあり対象を`personal_sign`のみに限定する前提。fable監査で確認済み: 現行実装はセッションの要求メソッドとして `personal_sign` に加え `eth_sendTransaction` も含めているが、実際に送っているのは digest 署名の `personal_sign` のみで、試算の前提とずれはない。要求メソッド一覧を実利用に合わせて絞るのは軽微な清掃候補）: 1 connector × 1 platform あたり PoC 2〜5人日、本番品質化 1〜2エンジニア週。MetaMask + Coinbase を iOS/Android 両方に入れる場合、共有抽象込みで概算4〜8エンジニア週。継続保守は主要なOS／ウォレット／SDK更新ごとに1統合面あたり1〜3人日程度。

Safe等のsmart accountをSIWEログイン対象に含める場合は、トランスポートとは別に、バックエンド検証を単純なECDSA recoveryだけで終わらせず、ERC-1271（必要ならERC-6492）への対応が必要になる点も留意。

## 4. 判断してほしいこと

- [ ] この対応方針（1・2に着手、3・4は利用実績次第、5は見送り）で進めてよいか
- [ ] Phase 1（`WalletConnector`抽象化 + テレメトリ設計）に着手してよいか
- [ ] Phase 3/4 着手の判断基準（利用率データ、Reown障害実績等）をどう定義するか、それとも「当面追わない」でよいか
- [ ] **却下した選択肢（§2）に見落としている前提や、検討漏れの選択肢はないか**（この文書はAIが作った叩き台であり、意図的に反証・再検討の余地を残している）
- [ ] **（四條さん向け）Levaracのプロトコルとして、wallet接続トランスポートの分散性は要件なのか、それとも単なるアプリ実装上のベンダー衛生（vendor hygiene）の問題なのか。** この整理次第で、Phase 3/4への投資判断の重みが変わる

## 5. 未検証事項

- **鮮度確認のみ**: 本ドラフトの技術的な現状認識は origin/main @ 0292314（PR#32まで反映、2026-07-12 12:17時点）で裏取り済み。GitHub接続復旧後、それ以降に新たなmergeが無いかだけ投稿前に確認する（merge状態そのものは既に確定事項）。
- Link Modeが最新のreown-swiftで実際にRelease buildで動くか、かつそれがSign層単独か・AppKit依存かの分岐（§2.7）。AppKit依存が必要と判明した場合は、AA不採用というチーム裁定との整合を四條さん・Kenを交えて再判断する。
- Coinbase Wallet Mobile SDKのiOS側の未解決issue（公開リポジトリで確認）が、beidの想定ユースケースに影響するか。

## 出典

GPT Pro (5.5 Pro) による2ラウンドのdeep research（一次情報付き）:
- reown-swift 2.3.0 ソース（`Relay.swift` 等）
- WalletConnect Pairing URI spec, Relay Server RPC spec
- WalletConnect Network公式ドキュメント（node-operators, wcn onboarding doc）
- 各ウォレット公式ドキュメント（MetaMask Connect, Coinbase Wallet Mobile SDK, Trust/Rainbow/imToken/Argent の接続ガイド）
- Reown Link Mode / One-Click Auth ドキュメント
- SIWE公式サイト、EIP-4361

社内記録（Ken限定の参照先、社外レビュワーは参照不可）:
- kura journal 2026-07-12 の WalletConnect relay 分散化調査・Link Mode spike確定結論ノート（Kenのprivateナレッジベース）
