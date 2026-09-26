# プライバシーラベル（App のプライバシー）の回答

App Store Connect の「App のプライバシー」に入れる回答と、**その根拠になるコード上の事実**。
根拠を先に書いてあるのは、実装が変わったらこの回答も変えなければならないからで、
根拠の無い「収集していません」は次の変更で静かに嘘になる。

## 手順は他と違う（公開 API から書けない）

`asc web privacy` のみ。Apple の Web セッション（Apple ID + 2 要素認証）が要り、API キーでは通らない。
実行手順は `docs/app-store/README.md` を参照。
**このファイルに選択肢のトークン名そのものを書いていないのは、`asc web privacy catalog` を
引かずに書くと綴りを推測することになるため。** 推測したトークンが正本として残るのが一番まずい。

## 根拠（`origin/main` 047fa4e7 に送信 ON の変更を加えた状態で確認、2026-09-26）

| 事実 | どこで確認したか |
| --- | --- |
| **イベント参加中、署名付き観測をサーバーに送る** | `ios/project.yml` の `BEID_REPORT_SUBMISSION_ENABLED: "YES"`（Ken 決定 2026-09-26）。Android は本番の `EventJoinCoordinator(activity)` が `ledgerFilesDir = activity.filesDir` を渡すので、送信（`WindowObservationSubmissionDrain`）が以前から動いている |
| 送るのは署名付き観測（COSE_Sign1）だけ | `shared/.../parallax/submission/SubmissionClient.kt` の POST 本文。中身は `ObservationV1`：イベントごとの仮名の鍵（`observer`）、聞こえた回転 RPID、自分の RPID、イベント ID（`context`）、ENIN と時刻、参加コミットメント（ハッシュ） |
| 名前・メール・電話・アカウント・端末 ID・ウォレットアドレス・緯度経度は含まない | 同上。ウォレットアドレスは端末内（`CachedWalletHint.swift`）に留まり、送信経路に無い |
| operator は受理した観測を無期限に保存する | operator の health endpoint が retention indefinite を返す。D1 に `signed_observation`, `acceptance_receipt`, `context`, `accepted_at`, `delegation_cert` を保存（`delegation_cert` は operator 側の値で、アプリは送らない） |
| operator は Levarac 自身が運営する | `parallax-observation-operator.levarac.workers.dev`。第三者への提供ではない |
| アカウントが無い | サインアップ画面も認証も存在しない。`OnboardingMode.current = .guestFirst`（`OnboardingMode.swift:19`） |
| 解析 SDK・広告・トラッキングが無い | Firebase / Crashlytics / Segment 等の依存が無い。IDFA も ATT も使っていない |
| MetaMask SDK の解析送信は止まっている | `MetaMaskConnector.swift` が `enableDebug: false` で構築。SDK の `Analytics.trackEvent` は `if !debug { return }` で戻る |

## 回答

### トラッキング

**「トラッキングに使用しています」= いいえ。** 他社のアプリやサイトをまたいでユーザーを追う仕組みが無く、
データブローカーにも渡していない。

### 収集するデータ（App Store「App のプライバシー」）

**「データを収集していません」はもう使えない。** 観測はデバイスの外に送られ、保存されるので、Apple の言う「収集」に当たる。

申告案（トークン名は `asc web privacy catalog` で確認してから書く。推測で書かない）:

1. **その他のデータ**（署名付き近接観測）
   - 目的: App の機能
   - ユーザーに紐づくか: **いいえ**。鍵はイベントごとの仮名で、アカウントも端末 ID も無い
   - トラッキング: いいえ
2. **おおよその位置情報**（要判断、申告する側を推奨）
   - 観測は「このイベント（会場と日時が公開されている）にいた」ことを示す。緯度経度は送っていないが、
     会場が公開されている以上、低解像度の位置情報に当たると読むのが安全側
   - 目的: App の機能 / ユーザーに紐づくか: いいえ / トラッキング: いいえ

### Google Play「データセーフティ」

- 収集: **あり**（上と同じ 2 種。「その他」と「おおよその位置情報」）。共有（第三者への提供）: なし
- 送信時の暗号化: あり（https）
- 必須か任意か: イベントに参加した時だけ送る。参加は任意
- 削除リクエスト: **未確認**。operator に削除の手段があるかを確認してから答える

Android は以前から送信しているので、Play の現行申告が「収集なし」なら、それは今すでに実態と食い違っている。

## 未確認 — 申告前に潰すべき点

1. **operator のアクセスログ**。リポジトリ上は保存していない（`operator/wrangler.jsonc` に observability / logpush /
   Analytics Engine / KV / R2 が無い）が、アカウント単位の Logpush と、デプロイ中の Worker が現設定と一致するかは
   Cloudflare ダッシュボードを見られる owner の確認が要る。保存しているなら「診断」の申告が加わる
2. **削除リクエストへの対応**（Play が問う）
3. **おおよその位置情報を申告するか**（上の 2。推奨は申告する）

## 変更に強くするために

このファイルの「根拠」表のどれかが変わる PR は、このファイルも一緒に変える。
とくに観測の中身（`ObservationV1`）にフィールドを足す変更と、ウォレットアドレスや端末識別子を
送信経路に載せる変更は、「ユーザーに紐づくか」の答えを変える。
