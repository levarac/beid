# WalletConnect relay 依存の扱い方

> 位置づけ: AI エージェント（Claude Code）が Ken との調査セッション（GPT Pro deep research 2ラウンド、fable-oracle による監査込み）をもとに作成した叩き台である。決定ではなく検討材料として書いている。

## 背景

WalletConnect の relay は、Reown 社のクラウドを経由する。一社のインフラに依存する構成は、web3 の作法からすれば据わりが悪い。最初に浮かんだ問いはコストだった。Reown Cloud は高いのではないか。

調べると、これは早々に答えが出た。beid は WalletConnect 実装の入ったビルドをまだ TestFlight に上げていない。実利用者はゼロで、Free tier の上限（月間アクティブユーザー500人）にはまだ遠い。コストは当面問題にならない。

問題として残ったのは、Reown という一社への依存を、どこまで、どうやって減らせるかという一点だった。

beid の wallet 接続には WalletConnect v2（reown-swift 2.3.0）が使われている。実装は 2026-07-11、PR#27 として `main` に入った。

## 自前で relay を立てる案

自分で relay を立てる案が、まず浮かぶ。オープンソースなのだから、できるはずだと考えた。

公式リポジトリを確認すると、様子が違った。`WalletConnect/relay` は2024年5月28日に archive されている。README には production 利用は推奨しないと明記され、セルフホストは現状サポート対象外だとも書かれていた。位置づけは教育用のサンプル実装であり、本番運用できる配布物ではない。

自作するなら、常時稼働の WebSocket、JWT 認証、永続メールボックス、再送と冪等性の処理、水平スケーリング、DDoS 対策、多リージョンでの可用性、24時間の監視が要る。個人開発や小規模なチームの手には余る規模である。

## ノードオペレーターという道

自分で作れないなら、既にあるネットワークに加わればよい。WalletConnect Network は、Service Node と Gateway Node からなる分散ネットワークとして実際に動いている。Consensys、Ledger、Kiln、Figment など、名の知れたインフラ事業者が20社以上、ノードを運用している。

好都合な事実があった。Levarac は Ethereum の solo validator を既に運用している。geth と Prysm を動かし、常時稼働のための監視体制と鍵管理も、すでに手元にある。このクラスのノードを回すための下地は整っていた。ハードウェア要件を見ても、Node二台（各4CPU/8GB RAM）と Database一台（8CPU/16GB RAM/200GB SSD）で足りる。validator を運用しているチームにとって、法外な規模ではない。

あとはノードを二台立てて、名乗りを上げるだけのはずだった。

ところが、公式サイトの記載は違った。ノードアクセスは現状まだ許可制であり、個人が自由に参加できる段階ではないという。参加には WalletConnect のチームへの直接連絡と、配置リージョンの交渉が要る。名を連ねているのは、いずれも機関クラスの事業者だった。

技術的な下地があることと、参加の窓口が開いていることは、別の話だった。将来、完全 permissionless な Phase 3 が始まれば話は変わる。コストのかからない監視項目として、この移行のタイミングを見ておく価値はある。

## 既存の分散ネットワークへの転用

ノードオペレーターの道が閉じているなら、他の分散ネットワークを転用できないか。Waku、Nostr、libp2p、IPFS Pubsub、そして Ethereum の devp2p（Levarac が今まさに運用している validator が繋がっているネットワークそのもの）を候補に、六つを確かめた。

一番近いのは Waku だった。Relay、Store、Filter、Light Push という、WalletConnect の relay に近い機能一式を、既に備えた共有ネットワークがそこにある。オフライン端末を意識した設計まである。

しかし、どの候補にも共通する壁があった。dApp 側だけが対応しても、繋がらない。WalletConnect の Pairing URI には `relay-protocol` という項目があり、通常は `irn` という値が入る。ウォレット側に「別のネットワークに繋いでくれ」と指示するフィールドは、どこにも用意されていない。MetaMask も Rainbow も、それぞれが実装した経路でしか話さない。beid だけが Waku に乗り換えれば、既製のウォレットとは繋がらなくなる。

Ethereum の devp2p については、話はさらに単純だった。RLPx は、あらかじめ合意した通信の種類（`eth` や `snap` など）しか運ばない設計になっている。今動いている validator のネットワークを、そのまま転用できるわけではない。

| 候補 | 評価 | 主な障壁 |
|---|---|---|
| Waku | 一番近いが drop-in の代替にはならない | dApp とウォレット双方の改修が要る |
| Nostr | 小規模な実験は容易 | relay ごとにルールがばらばらで本番基盤としては弱い |
| libp2p | 転用候補ではない | 共有ネットワークではなくツールキットで、結局自分でネットワークを設計することになる |
| IPFS Pubsub | 不適 | experimental 扱いでデフォルト無効 |
| Ethereum devp2p | 不適 | 事前合意した通信種別しか運ばない |

Waku に限れば、beid と Levarac 管理下の実験用ウォレットの双方を改修し、暗号化済み WalletConnect メッセージを Waku 経由で運べるか確かめる研究の余地は残る。ただしそれは、独自の WalletConnect 派生クライアント同士の通信であって、既製ウォレットとの互換性を諦める前提になる。

## SIWE は別のレイヤーの話

「EOA でログインできればよい」という条件だけを見れば、Sign-In with Ethereum（SIWE、EIP-4361）が候補に挙がってもおかしくない。login.xyz という名前を見た人なら、なおさらだろう。

SIWE が決めているのは、署名するメッセージの型である。そのメッセージをどうやってウォレットに届けるかは、SIWE の範囲外にある。実際、モバイルで SIWE を使う実装のほとんどは、WalletConnect を橋渡し役として使う。SIWE を採用しても、接続経路の問題はそのまま残る。

無関係というわけではない。beid が今使っている独自スキーマ `AttendanceProof/v1` の代わりに、広く使われる EIP-4361 に寄せるという選択肢は、beid#33 の署名ペイロード設計の議論に効いてくる。ただし、それは relay 依存とは別の議論である。

## 個別ウォレットへの直結

もう一つの道が残っていた。WalletConnect を介さず、主要なウォレットに直接繋げばよい。MetaMask には専用の SDK がある。relay 不要で繋がる、と当初は理解していた。

これは誤りだった。MetaMask Connect が経由しないのは Reown の relay であって、relay という仕組みそのものではない。MetaMask 自身が用意した別の deeplink relay を使っている。依存先が Reown から MetaMask に移るだけで、relay という構造は残る。

九つの主要ウォレットを確かめると、relay 不要と言えるのは Coinbase Wallet だけだった。

| ウォレット | 判定 | 備考 |
|---|---|---|
| Coinbase Wallet | relay 不要 | Universal Link 経由の直接通信。公式に relay サーバー不要と明記されている |
| MetaMask | relay の乗り換えにとどまる | 別の deeplink relay を使う。Reown への依存分散にはなるが、relay 除去にはならない |
| Trust Wallet / Rainbow / imToken / Argent | 直結 SDK なし | 公式の外部 dApp 接続方法はいずれも WalletConnect |
| OKX Wallet | 限定的 | 接続経路はあるが、本格的な Swift/Kotlin SDK ではない |
| Ledger / Safe | 該当なし | 外部 dApp から接続する汎用 SDK という設計思想自体がない |

複数ウォレットの直結 SDK を束ねて WalletConnect なしで広いカバレッジを得る、成熟したアグリゲーターも探した。存在しなかった。Dynamic のようなライブラリの中身を開けても、結局は「ブラウザ標準（EIP-6963）と Coinbase 固有の経路、それ以外は全部 WalletConnect」という構成に行き着く。Privy、Web3Auth、Magic も同様で、既存の外部ウォレットとの接続自体は WalletConnect に委ねている。導入すれば、依存する SaaS が一つ増えるだけになる。

## Link Mode という近道、その先にある分岐

残る近道は Link Mode だった。対応するウォレットが相手なら、Universal Link 経由でセッションのやり取りを運び、relay を経由しない。reown-swift には、そのための下位 API が確かに存在する。

ただし、今 beid が使っている reown-swift 2.3.0 では、この経路は塞がれている。Link Mode 専用の三つのメソッドは `#if DEBUG` で囲われていて、Release build には存在しない。2026-07-12 の spike 検証で、ソースを直接読んで確認した事実である。

最新の AppKit では有効化できる、という記載も見つかった。ここに見過ごせない分岐がある。beid の実装は、Reown AppKit を避けて低レベルの Sign + Pairing API だけを使う設計になっている。project.yml のコメントには、その理由が明記されていた。AppKit が引き込む CoinbaseWalletSDK の余分な範囲が、beid の「アカウントアブストラクション不採用」という 2026-07-09 の裁定に合わない、という理由である。

Link Mode の再検証には、したがって二つの結末があり得る。Sign 層だけで gate が外れるなら、安く済む。AppKit 経由でしか使えないなら、一度決めたはずの設計判断を、この一件のためだけに覆すかどうかという話になる。技術の選択ではなく、チームの裁定に触れる話になる。

Link Mode を使っても、対応の判定自体は relay 経由の往復を一度経てから行う設計であり、確立の段階は依然として relay を必要とする。relay を経由しなくなるのは、確立した後のやり取りに限られる。project ID や Explorer 設定という前提も残るため、Reown からの完全な独立策にはならない。

## 推奨する対応

選択肢を一つずつ確かめると、手元に残るものは多くない。派手な解決策はなかった。今すぐ安く効く一手と、条件が整えば効いてくる二手が残った。

まず、`WalletConnector` という薄い抽象を挟む。

```
WalletConnector
  connect()
  personalSign(message)
  handleRedirect(url)
  disconnect()
```

SIWE メッセージの生成、nonce の管理、domain と URI の検査、署名の検証は Connector から分離し、`ReownConnector`、`MetaMaskConnector`、`CoinbaseConnector` のような実装だけを差し替えられるようにする。これ自体で何かが解決するわけではない。ただし、次にどの選択をするにせよ、境界を先に切っておけば、あとからの差し替えは安く済む。

低頻度の署名だからこそ、壊れていても気づかれにくい。接続方式ごとの成功率、相手ウォレットの識別、relay 到達不能かどうかの障害分類まで、テレメトリに含めておく必要がある。この三つ目がないと、後述する条件付きの二手（MetaMask や Coinbase の利用実績、Reown 障害の実績)自体が測定できない。beid は近接情報を扱うプライバシー配慮アプリでもあるため、何を収集し、どこに送るかは一言明記しておく。

次に、reown-swift を最新版に上げ、Link Mode が実際に Release build で有効化できるかを確かめる。Sign 層で済むのか、AppKit が要るのかという分岐は、ここで初めて答えが出る。AppKit 側に転んだ場合は、独断で進めない。アカウントアブストラクション不採用というチームの裁定に触れる話であり、四條さんと Ken を含めた判断に上げる。

MetaMask と Coinbase への対応は、条件が整ってから考える。MetaMask の利用実績や Reown 障害の実績が積み上がった段階で、到達性の確保を目的に MetaMask Connect を追加するかを判断する。relay を減らす目的ではなく、Reown が落ちたときの保険としての位置づけになる。Coinbase Wallet の利用率が十分にあり、iOS と Android での実証が通った場合に限り、真に relay 不要な経路として Coinbase Mobile Wallet Protocol を追加する。AppKit を採用した場合は CoinbaseWalletSDK が既にバンドルされているため、この一手のコストは一部相殺される。

個別ウォレットの SDK を数多く統合すること、relay 回避だけを目的に Privy や Dynamic へ全面移行すること、Waku や Nostr へ切り替えることは、いずれも追わない。既製ウォレットとの互換性を失う代償が大きすぎる。

工数の目安は、既存の SIWE バックエンドがあり、対象を `personal_sign` に限定する前提で、connector 一つにつき platform 一つあたり、PoC が2から5人日、本番品質化が1から2エンジニア週になる。MetaMask と Coinbase を iOS と Android の両方に入れる場合、共有する抽象の実装を含めて4から8エンジニア週になる。継続保守は、OS やウォレットや SDK の更新のたびに、統合面一つあたり1から3人日を見込む。現行実装はセッションの要求メソッドとして `personal_sign` に加えて `eth_sendTransaction` も含めているが、実際に送っているのは digest 署名の `personal_sign` のみであり、工数の前提とはずれない。要求メソッドの一覧を実利用に合わせて絞るのは、軽微な整理の候補として残しておく。

Safe のような smart account を SIWE ログインの対象に含める場合は、接続経路とは別に、バックエンドの検証を単純な ECDSA recovery だけで終わらせず、ERC-1271（未デプロイのアカウントには ERC-6492）への対応が要る。

## 判断してほしいこと

- この対応方針で進めてよいか。`WalletConnector` の抽象化と、Link Mode の再検証には着手し、MetaMask と Coinbase への対応は利用実績が出るまで条件付きで保留し、その他は追わないという整理である。1 から 5 を順番に実行するという意味ではない。
- 却下した選択肢に見落としている前提はないか、検討漏れの選択肢はないか。この調査は AI 主導であり、反証と再検討の余地を残している。
- wallet 接続トランスポートの分散性は、Levarac のプロトコルが要求することなのか、それともアプリ実装のベンダー衛生の問題にとどまるのか。ここの整理次第で、MetaMask や Coinbase への投資判断の重みが変わってくる。ここは四條さんの持ち場だと思う。

## 未検証事項

技術的な現状認識は、origin/main の 0292314（PR#32 まで反映、2026-07-12 12:17 時点）で裏取り済みである。それより後に新たな merge がないかは、投稿前に確認する必要がある。

Link Mode が最新の reown-swift で実際に Release build で動くか、それが Sign 層単独で済むのか AppKit 依存になるのかという分岐も、まだ確かめていない。AppKit 依存が要ると判明した場合は、アカウントアブストラクション不採用という裁定との整合を、四條さんと Ken を交えて判断し直す。

Coinbase Wallet Mobile SDK の iOS 側には未解決の issue が公開リポジトリに残っている。beid の想定するユースケースに影響するかどうかも、確かめていない。

## 出典

GPT Pro（5.5 Pro）による2ラウンドの deep research と、一次情報の直接確認による。

- reown-swift 2.3.0 のソース（`Relay.swift` など）
- WalletConnect の Pairing URI spec、Relay Server RPC spec
- WalletConnect Network の公式ドキュメント（node-operators、wcn onboarding doc）
- 各ウォレットの公式ドキュメント（MetaMask Connect、Coinbase Wallet Mobile SDK、Trust、Rainbow、imToken、Argent の接続ガイド）
- Reown の Link Mode、One-Click Auth のドキュメント
- SIWE 公式サイト、EIP-4361

社内の参照先（Ken 限定、社外のレビュワーは参照できない）:

- kura journal 2026-07-12 の WalletConnect relay 分散化調査、Link Mode spike の確定結論ノート
