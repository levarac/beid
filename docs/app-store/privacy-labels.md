# プライバシーラベル（App のプライバシー）の回答

App Store Connect の「App のプライバシー」に入れる回答と、**その根拠になるコード上の事実**。
根拠を先に書いてあるのは、実装が変わったらこの回答も変えなければならないからで、
根拠の無い「収集していません」は次の変更で静かに嘘になる。

## 手順は他と違う（公開 API から書けない）

`asc web privacy` のみ。Apple の Web セッション（Apple ID + 2 要素認証）が要り、API キーでは通らない。
実行手順は `docs/app-store/README.md` を参照。
**このファイルに選択肢のトークン名そのものを書いていないのは、`asc web privacy catalog` を
引かずに書くと綴りを推測することになるため。** 推測したトークンが正本として残るのが一番まずい。

## 根拠（すべて `origin/main` 4c99036 で確認）

| 事実 | どこで確認したか |
| --- | --- |
| 観測データをサーバーに送らない | `ios/project.yml` の `BEID_REPORT_SUBMISSION_ENABLED: "NO"`。リリースビルドを作る `scripts/gha/build-and-upload-ios.sh` は `-configuration Release` で archive するだけで、この設定を上書きしていない。アプリ側は `ReportSubmissionRuntime.swift:552` で Info.plist から読む |
| アカウントが無い | サインアップ画面も認証も存在しない。オンボーディングは `OnboardingMode.current = .guestFirst`（`OnboardingMode.swift:19`） |
| 解析 SDK が無い | Firebase / Crashlytics / Segment 等の依存が無い。SPM 依存は barnard, MetaMask SDK, Socket.IO, Starscream のみ |
| **MetaMask SDK の解析送信が止まっている** | `MetaMaskConnector.swift:339-346` が `enableDebug: false` で SDK を構築している。SDK 側の `Analytics.trackEvent` は `if !debug { return }` で即座に戻る（`metamask-ios-sdk/Classes/Analytics/Analytics.swift`）。したがって `metamask-sdk.api.cx.metamask.io/evt` への送信は発生しない |
| MetaMask との通信がリレー経由でない | 同じ構築箇所で `transport: .deeplinking(dappScheme: "beid")`。ソケットリレーではなく端末内のディープリンクで MetaMask アプリと往復する |
| 広告・トラッキングが無い | IDFA も ATT も使っていない。`NSUserTrackingUsageDescription` は不要 |
| 端末間で個人情報が飛ばない | 交換されるのは回転する識別子と署名付き観測。アプリ内文言も「Only anonymous proofs are exchanged, never your identity.」 |

## 回答

### トラッキング

**「トラッキングに使用しています」= いいえ。**
他社のアプリやサイトをまたいでユーザーを追う仕組みが無く、データブローカーにも渡していない。

### 収集するデータ

**「データを収集していません」で申告する。**

beid が外に出す通信は次の 3 つだけで、いずれも**ユーザーに紐づくデータを送っていない**。

1. イベント定義・鍵セットの取得（`parallax-observation-operator.levarac.workers.dev/artifacts/...`）。
   送るのはダイジェスト値だけ。
2. イベントコードの照合（同ホストの `/v1/events/by-code/...`）。送るのは主催者が配ったコードだけ。
3. レジストリの読み取り。

いずれもリクエストに付随して IP アドレスは当然サーバーに届くが、
Apple のプライバシーラベルは「識別子として収集・保存しているか」を問うものであり、
**通信に伴う一時的な IP は、それ自体を保存・利用していない限り収集に当たらない**という整理。
operator 側でアクセスログを保存している場合は話が変わるので、下の「未確認」を参照。

### ウォレットアドレスの扱い

ウォレットを接続すると、アドレスは**端末内に保存される**（`CachedWalletHint.swift`）。
アドレスは MetaMask アプリとの間でやり取りされるが、**beid のサーバーには送られない**
（観測の送信自体が止まっているため）。
端末内に留まるデータは Apple の言う「収集」に当たらない。

## 未確認 — 申告前に潰すべき 1 点

**operator（`parallax-observation-operator.levarac.workers.dev`）がアクセスログを保存しているか。**

保存していて、かつそれを解析等に使っているなら、「診断」または「使用状況データ」の申告が要る可能性がある。
Cloudflare Workers の既定のログ保持だけであれば通常は申告不要の範囲。
**これは私（prep-review）が確認できておらず、operator を持っている側に確認が要る。**
「データを収集していません」は強い主張なので、これを確認しないまま出すべきではない。

## 変更に強くするために

このファイルの「根拠」表のどれかが変わる PR は、このファイルも一緒に変える。
とくに **`BEID_REPORT_SUBMISSION_ENABLED` を `YES` にする変更は、
プライバシーラベルを「データを収集していません」から書き換える必要がある**。
その変更だけでストア上の申告が実態と食い違う状態になる。
