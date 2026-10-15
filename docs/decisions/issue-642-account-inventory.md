# beid#642 — いまの Account シートにある物の棚卸しと、新デザインでの行き先

読む人: デザイナー(Xcode を開かない人)。
書いた人: Worker a-20260923-060。作成日 2026-09-23。
測った対象: ブランチ `work/issue-644-642-inventory`、コミット `e24f0d6`。

**この文書は決めません。** 決めるのに必要な事実を全部そろえて、
決める手間を安くするためだけの物です。最後の「デザイナーに聞きたいこと」
だけが、あなたに答えてほしい部分です。それ以外は読み物です。

新デザイン(Flat 2b)側の数値は、すべて **SubPM 実測 (2026-09-23, Figma `183:2`)**
です。この文書を書いた Worker は Figma を自分では開いていません。

---

## 0. 先に結論だけ

いまの Account シートには **行が 8 つ**あります(issue #642 の表は 7 項目を挙げて
いますが、その表は 2 つを取り違え、3 つを落としています。詳細は §6.1)。

8 つのうち **7 つは、アプリの中で他にどこからも辿り着けません**。
Account シートが唯一の入り口です。残る 1 つ(`Join Event`)だけは別経路があります。

**数え方について。** 以下では **11 項目**を仕分けます。行は 8 つなのに 11 になるのは、
行以外に次の 3 つを別立てで数えるからです —— ①`Connect Wallet`(9 本目の行ではなく、
ウォレット未接続のときに 1 行目が姿を変えた物)、②Bluetooth 行の下に出る中継の注記
(行ではなく、行に付く説明文)、③右上の `Done`(行ではなく、シートを閉じる部品)。
**行は 8 つ、仕分ける物は 11 個。**どちらも正しく、間違いではありません。

新デザインでの行き先を 3 つに分けると:

| 分類 | 数 | 中身 |
|---|---|---|
| **移設** — 残る。行き先が決まっている | 5 | ウォレットアドレス+コピー、Bluetooth、`Venue broadcast`、`Disconnect Wallet`、`Version` |
| **廃止** — 行き先なし。意図的に消す。聞く必要なし | 2 | `Leave Event`、`Join Event` |
| **行き先未定** — 本当に決まっていない | 4 | `Connect Wallet`、Bluetooth 行の下の中継の注記、`Past Events`、`Done` |
| | **計 11** | |

**デザイナーに聞きたいことは §4 に 7 件**あります。うち **4 件**は上の「行き先未定」を
そのまま質問にした物(Q1・Q2・Q3・Q5)。残り **3 件**は、行き先は決まっているが形や
文言が変わる物(Q4 ビルド表記)、新デザインで新しく増える物(Q6 `Venue device`)、
そして #642 の受け入れ基準が名指しで求めている物(Q7 アドレスの書体)です。

---

## 1. どうやって数えたか(方法と、その限界)

この節は「数が正しいと信じてよいか」を読む人が自分で判定するためにあります。
興味がなければ §2 へ飛んでください。

### 1.1 使ったコマンド

作業ディレクトリは `/Users/ko/Workspace/levarac/beid-worktrees/issue-644-inventory`。

```
# シート本体を 1 行も飛ばさず読む
cat -n ios/Beid/Views/AccountSheetView.swift

# Account シートを出しているのは誰か
git grep -nP 'AccountSheetView' -- ios/Beid/
git grep -nP 'accountSheetPresented' -- ios/Beid/

# 各行の飛び先に、他の入り口があるか
git grep -nP 'VenueSignedServingView' -- ios/Beid/
git grep -nP 'PastEventsView'         -- ios/Beid/
git grep -nP 'EventCodeEntryView'     -- ios/Beid/
git grep -nP 'VenueDeviceOrganizerView' -- . ':!ios/Beid.xcodeproj'
git grep -nP 'WalletConnectPairingView' -- ios/Beid/

# 各行の「する事」を、実際に処理する関数まで辿る
git grep -nP 'disconnectWallet|leaveEvent|rejoinPastEventResolvingCanonicalId' -- ios/Beid/
git grep -nP 'openEventCodeEntryFromAccountSheet|connectWalletFromAccountSheet' -- ios/Beid/
git grep -nP 'AppVersion' -- ios/Beid/
git grep -nP 'isPoweredOff|evaluateBluetoothState|applyBluetoothState' -- ios/Beid/

# 画面遷移の全経路を一覧にして、見落としが無いことを確かめる
git grep -nP '\.sheet\(|\.fullScreenCover\(|navigationDestination\(|NavigationLink \{|NavigationLink\(' -- ios/Beid/

# 「How sensing works」がアプリに無いことの確認
git grep -rniP 'how sensing works' -- ios/     # → 0 件(終了コード 1)

# 書体トークン
git grep -rn 'ledgerMono' -- ios/
```

最後の「画面遷移の全経路」は、本番コード全体で **15 行に一致し、うち 1 行は
コメントなので、実際の画面遷移は 14 箇所しかありません**。
アプリの画面遷移はこの 14 行で全部です。だから §2 の「他に入り口は無い」は、
網を広げて見つからなかったという話ではなく、全部を数え上げた結果です。

### 1.2 このホスト特有の罠(数を信じる前に)

**`git grep -E` は、このホストでは `\b`(単語境界)を黙って無視します。**
一致 0 件・終了コード 1 を返すので、「その識別子はどこにも無い」と読めてしまいます。
実際に確かめました:

```
git grep -cE '\bAccountSheetView\b' -- ios/   → 0 件(終了コード 1)  ← 嘘
git grep -cP '\bAccountSheetView\b' -- ios/   → 11 ファイル          ← 正しい
```

この文書の数はすべて `-P`(または `([^A-Za-z0-9_]|$)` を明示的に書いた形)で
数え直してあります。

### 1.3 この方法が見落とす物

正直に書きます。以下はこの調べ方では捕まえられません。

- **文字列から組み立てられる画面遷移。** 型名を直接書かずに遷移する書き方があれば、
  識別子の grep には出ません。§1.1 の「画面遷移の全経路」15 箇所を目で見て、
  そういう書き方は無いことを確認しましたが、確認の根拠は目視です。
- **実機での実際の見え方。** ビルドも実行もしていません。この文書は
  ソースコードと設計文書だけを根拠にしています。行が画面上でどう折り返すか、
  どの行がスクロールしないと見えないかは、コード中のコメントとテストの記述
  (§2 の R7 を参照)から引いた二次情報です。
- **Android 側。** #642 は iOS の画面です。Android の Account 画面は
  別物で、この棚卸しには含めていません。
- **Figma の現物。** SubPM の実測値を使っています。Worker は Figma を開いていません。

---

## 2. Part 1 — いまの Account シートにある物、全部

場所はすべて `ios/Beid/Views/AccountSheetView.swift`。
行番号は `e24f0d6` 時点の物です。

シートは **ホーム画面(Collection)の右上の人物アイコン**からだけ開きます
(`CollectionHomeView.swift:93–101` がボタン、`:111` がシート)。
開き方は「画面の半分の高さ」固定(`.presentationDetents([.medium])`,
`CollectionHomeView.swift:114`)。

---

### R1. ウォレットアドレス行 — `:18–48`

| | |
|---|---|
| **見えるもの** | 財布アイコン + 切り詰めたアドレス + その下に小さく `Connected via MetaMask` + 右端にコピーアイコン |
| **文言(原文)** | アドレスは `0x1234...5678` 形(先頭 6 文字 + `...` + 末尾 4 文字、`truncated(_:)` `:219–224`)。副文は `"Connected via \(connectorDisplayName)"`(`:193–198`、文字列キー `account.wallet.connectedVia`) |
| **する事** | コピーアイコンを押すと、**省略していない完全なアドレス**がクリップボードに入る(`:34`)+ 触覚フィードバック。読み上げ用ラベルは `"Copy address"`(`:44`) |
| **他に入り口は** | **ありません。**接続中のアドレスをアプリ内で見られるのはここだけです |
| **出る条件** | ウォレットが接続済みのとき(`walletAddress != nil`) |

`Connected via ...` の「...」はウォレットの種類の名前です(`:203–217`)。
本番では常に `MetaMask`。開発ビルドでのみ `Demo Wallet` になります。
**つまり、いまのアプリは「MetaMask で接続中」と書いています。**
新デザインの `CONNECTED VIA WALLETCONNECT` はプロトコルの名前です(§4 の末尾の**付記**)。

---

### R1'. `Connect Wallet` ボタン — `:50–55`

R1 と入れ替わりで出る、同じ場所の別の姿です。

| | |
|---|---|
| **見えるもの** | 財布アイコン + `Connect Wallet` |
| **する事** | `connectWalletFromAccountSheet()`(`AppCoordinator.swift:538–540`)→ ウォレット接続シートが上に重なって出る(`:146–149`, `:232–267`) |
| **他に入り口は** | オンボーディング中の接続画面と、イベント結び付けシート(`EventBindingSheetView.swift:144`)にあります。**ただしオンボーディングは一度終わると二度と戻りません**(`AppCoordinator.swift:522` で完了フラグが立つ)。**オンボーディングを終えた人が、自分の意思でウォレットを繋ぎに行ける場所はここだけです** |
| **出る条件** | ウォレットが未接続のとき(`walletAddress == nil`) |

**この行が消えると詰む人:** R4(`Disconnect Wallet`)を押した直後の人。
切断すると `walletAddress` が `nil` に戻り(`AppCoordinator.swift:559–565`)、
画面遷移は起きません。つまりホームに居たまま、ウォレットの無い状態になります。
いまはこの行が「もう一度繋ぐ」受け皿になっています。→ §4 の Q1。

---

### R2. Bluetooth 行 — `:59–81`

| | |
|---|---|
| **見えるもの** | 電波アイコン + `Bluetooth` + 右端に色つきの丸 + `Active` または `Off`(`:178–180`) |
| **する事** | **何もしません。**押せません。状態を見せるだけです |
| **下の注記** | `While this phone is at an event, beid can pass the event's details on to phones nearby, so people across the venue can still find it.`(`:182–191`、キー `account.bluetooth.relayNote`)。日本語にすると「このスマホがイベント会場にいる間、beid はイベントの情報を近くのスマホに中継することがあります。会場の反対側の人でもイベントを見つけられるように」 |
| **他に入り口は** | **実質ありません。**下に詳しく書きます |
| **出る条件** | 無条件。常に出ます |

**「実質ありません」の中身。** アプリには Bluetooth が切れている専用画面
(`BluetoothOffView`)があります。そこへ飛ばす処理
(`applyBluetoothState`, `AppCoordinator.swift:516–533`)が動くのは、次の 3 つだけです:

1. オンボーディング中
2. **アプリの起動時**(`AppCoordinator.swift:89–91` → `restoreAfterOnboarding()`
   `:143–148`。一度セットアップを終えた端末でも、起動のたびに同じ判定を通ります)
3. その専用画面自身の「再試行」ボタン(`BluetoothOffView.swift:36`。
   `evaluateBluetoothState` の呼び出し元はこの 1 箇所だけです)

**アプリを使っている最中、および背面から前面に戻ったときの再判定はありません。**

**この行が消えると詰む人:** アプリを開いたままイベント会場で Bluetooth を切った人、
あるいは他のアプリを使っている間に切って beid に戻ってきた人。
イベントを探せなくなりますが、**アプリを完全に起動し直すまで、
どの画面もそれを知らせません。**気づける場所はこの行だけです。

新デザインはこの行を残し、さらに `10c Bluetooth off` という状態まで
描き足しています(SubPM 実測)。上の事情と合っています。

---

### R3. `Venue broadcast` — `:96–108`

| | |
|---|---|
| **見えるもの** | アンテナアイコン + `Venue broadcast` + 右向き矢印 |
| **する事** | 会場発信の画面(`VenueSignedServingView`)へ進む。その画面は「この端末がいま預かっているイベントのパック」を主語にして、貼り付け・読み取り・更新・停止を並べた物です |
| **他に入り口は** | **ありません。**`VenueSignedServingView` を本番で開いているのはこの 1 行だけです |
| **出る条件** | **無条件。**会場の運営者でなくても、全員に見えています |

**issue #642 の表はここを 2 行だと書いていますが、いまは 1 行です。**
表にある「Venue device(会場発信 v1)」は、**#597 ですでにこのシートから外されています**
(`:83–95` のコメントが理由を書いています ——「会場の入り口は 2 つではなく 1 つ。
運営者が持っているのはイベントのパックであって、中身が署名されているかどうかは
仕組みの話で、本人に選ばせる事ではない」)。

その v1 の画面(`VenueDeviceOrganizerView`)は削除はされておらず、
**ただし本番からは 1 箇所も呼ばれていません。**
リポジトリ全体で実体化しているのは自分自身のプレビュー 2 箇所だけです
(`VenueDeviceOrganizerView.swift:178`, `:184`)。
つまり **いまのアプリで、この画面に辿り着ける利用者は 1 人もいません。**
(裏側の処理のテストは生きています ——
`ios/BeidTests/VenueDeviceOrganizerViewModelTests.swift`。
なので戻すのは安いままです。`:87–88` のコメントも「`NavigationLink` 1 本で戻せる」と
書いています。)

→ 新デザインの `14 Organizer tools` が `Venue device` を並べている件は §4 の Q6。

---

### R4. `Disconnect Wallet` — `:110–118`

| | |
|---|---|
| **見えるもの** | 退出アイコン + `Disconnect Wallet`(赤) |
| **する事** | `disconnectWallet()`(`AppCoordinator.swift:559–565`)。アドレスを消し、ウォレットの接続状態を初期化し、保存してある接続ヒントも消す。**確認ダイアログは出ません。1 タップで即実行です** |
| **他に入り口は** | **ありません。**これがアプリ唯一の切断操作です(`AppCoordinator.swift:549–551` のコメントが明言) |
| **出る条件** | ウォレット未接続のときは押せない(`.disabled`, `:117`) |

新デザインは `10d Disconnect confirm` で確認を足しています(SubPM 実測)。
**これは今より安全になる変更です。**

---

### R5. `Join Event` — `:313–321`

| | |
|---|---|
| **見えるもの** | `#` アイコン + `Join Event`(キー `account.joinEvent.label`) |
| **する事** | イベントコードを手で入力するシートが上に出る(`:160–171`, `:276–297`)。コードが通ればシートが閉じて参加状態になる |
| **他に入り口は** | **あります。** ① センシング画面(まだ参加前=探索中のとき)の下端ボタン `Enter event code`(`SensingView.swift:168–179`、キー `nearbyEvent.manualEntry.button`)。② オンボーディング中の同じ画面(`RootView.swift:17`) |
| **出る条件** | すでにイベントに参加中なら押せない(`.disabled`, `:320`) |

**この行が消えても誰も詰みません。**手入力の入り口はセンシング画面に残ります。
新デザインでも `13 Enter Event Code` への入り口は
`04b Events — Empty` / `05a2 Sensing — Detecting (20 s+)` / `05d Sensing — Can't join`
の 3 つで、**Account からは繋がっていません**(SubPM 実測)。
ウォレット必須化(#649)とも整合します。

---

### R6. `Past Events` — `:323–337`

| | |
|---|---|
| **見えるもの** | 巻き戻し時計アイコン + `Past Events`(キー `account.pastEvents.label`) |
| **する事** | 過去に参加したイベントの一覧(`PastEventsView`)へ進む。そこから 1 つ選ぶと、**コードを打ち直さずに再参加**できる(`rejoinPastEventResolvingCanonicalId`, `AppCoordinator.swift:424`) |
| **他に入り口は** | **ありません。**`PastEventsView` を本番で開いているのはこの 1 行だけ。再参加の処理を呼んでいるのもこの 1 箇所だけです |
| **出る条件** | 無条件 |

**この行が消えると詰む人:** 昨日参加したイベントに今日また参加したい人。
コードを覚えていなければ、**再参加する手段が無くなります。**
手入力の画面は残りますが、そこはコードを知っている前提の画面です。

→ **これが #642 で唯一の、本当の行き止まりです。** §4 の Q3。

---

### R7. `Leave Event` — `:339–347`

| | |
|---|---|
| **見えるもの** | 退出アイコン + `Leave Event`(赤) |
| **する事** | `leaveEvent()`。参加中のイベントから抜ける。**確認なし** |
| **他に入り口は** | ありません |
| **出る条件** | イベント未参加なら押せない(`.disabled`, `:346`) |

**すでに廃止が決まっています**(2026-09-23、デザイナー決定・オーナー承認、#655)。
参加をやめる手段は Sensing の `CLOSE` に一本化され、確認 05e が入ります。
**この文書では質問にしません。**

なおこの行については、画面に収まっていない証拠がコード中にあります。
UI テストが「シートは半分の高さで開くので、`Leave Event` を含む下のほうの行は
**スクロールしないと存在すらしない**」と書いて、実際にスクロールしています
(`ios/BeidUITests/EventMembershipUITests.swift:32–37`)。
**いまの 8 行は、すでに 1 画面に入っていません。**

---

### R8. `Version` — `:126–134`

| | |
|---|---|
| **見えるもの** | 左に `Version`、右に `1.0.0 (1234+374)` のような文字列 |
| **その数字の意味** | `AppVersion.swift:23–28`。`1.0.0` が製品版数、`1234` が **git の高さ**、`374` が配信ビルド番号。git の高さは「iOS と Android が同じコミットから作られたか」を突き合わせるためだけの数字(#491)。テスターから届く不具合報告を、iOS 側と Android 側で同じ物として扱えるようにする用途です |
| **他に入り口は** | **ありません。**`AppVersion.displayString()` の呼び出し元はこの 1 箇所だけ |
| **出る条件** | 無条件 |

新デザインのフッター `SENSEPROOF 1.0 · 4C99036` が受け皿です。
ただし **形が違います**(§4 の Q4)。

---

### C1. `Done`(右上) — `:140–144`

シートを閉じるボタン。新デザインの `10` は掴み手(grabber)だけで、`Done` を描いて
いません(SubPM 実測)。

これは一度決めた事です。`docs/specs/account-redesign.md` §5.2(2026-07-27 承認)が
「Figma は掴み手だけだが、**ドラッグだけで閉じる形はアクセシビリティが落ちる**ので
`Done` は残す」と決めています。→ §4 の Q5。

---

## 3. Part 2 — 対応表(廃止 / 移設 / 行き先未定)

新デザイン側で受け皿になれる場所は、この 5 つだけです(SubPM 実測):

- ウォレットの塊(`WALLET · CONNECTED VIA WALLETCONNECT` / アドレス / `COPY`)
- 行 1 `Bluetooth` + 緑の丸 `ACTIVE`
- 行 2 `Organizer tools →`
- 行 3 `Disconnect wallet`(赤)
- フッター `SENSEPROOF 1.0 · 4C99036 · ABOUT →`

| いまある物 | 分類 | 新デザインでの行き先 |
|---|---|---|
| R1 ウォレットアドレス + `COPY` | **移設** | ウォレットの塊。切り詰め方(先頭 6 + 末尾 4)も一致。書体は Figma 実測で見出し書体、確認のみ → Q7 |
| R1' `Connect Wallet` | **行き先未定** | 該当フレームなし。ウォレット必須化で「未接続の Account」を描く必要があるかが未定 → **Q1** |
| R2 Bluetooth の状態 | **移設** | 行 1。`10c Bluetooth off` まで描かれており、今より手厚い |
| R2 の下の中継の注記 | **行き先未定** | 3 行構成のどこにも入らない。`15 About sensing` か `16 What we send` が候補 → **Q2** |
| R3 `Venue broadcast` | **移設(1 段深くなる)** | 行 2 `Organizer tools →` → `14 Organizer tools` の中の `Venue broadcast`。**消えるのではなく、1 タップ遠くなります** |
| R4 `Disconnect Wallet` | **移設(今より安全に)** | 行 3 + `10d Disconnect confirm` の確認 |
| R5 `Join Event` | **廃止** | #649(ウォレット必須)で、ウォレットを飛ばす経路として削除。手入力自体は `04b` / `05a2` / `05d` から `13 Enter Event Code` に残る。**困る人はいません** |
| R6 `Past Events` | **行き先未定** | **Figma に該当フレームが 1 つもありません**(`Past events` はカンバス上 0 件、SubPM 実測)。いまの唯一の入り口が消えると再参加の手段が無くなる → **Q3** |
| R7 `Leave Event` | **廃止** | #655 で決定済み。`CLOSE` + 確認 05e に一本化。聞く必要なし |
| R8 `Version` | **移設(形が変わる)** | フッター `SENSEPROOF 1.0 · 4C99036`。ただし git の高さが落ちる → **Q4** |
| C1 `Done` | **行き先未定** | Figma は掴み手のみ。2026-07-27 の承認済み決定と衝突 → **Q5** |

新デザイン側に**新しく増える**物(いまのアプリに対応物が無い物):

| 新デザインの要素 | いまのアプリ |
|---|---|
| `Organizer tools →`(行 2) | 中身の `Venue broadcast` はある。まとめ役の階層が新設 |
| `Organizer tools` の中の `Venue device` | **画面は残っているが、#597 で入り口を外した物** → **Q6** |
| `Organizer tools` の中の `VENUE KEY` | 無し(別 issue) |
| フッターの `ABOUT →` → `15 About sensing` | 無し。`How sensing works` は `ios/` 全体で 0 件。2026-07-27 に「行き先と文面が決まるまで見送る」と決めた物(`docs/specs/account-redesign.md` §5.1) |

---

## 4. デザイナーに聞きたいこと(7 件)

答えは選ぶだけで済むようにしてあります。
**「廃止」に分類した物(`Join Event` / `Leave Event`)は入れていません。**

---

### Q1 — ウォレットを切断した直後、利用者はどの画面に居ますか?

`Disconnect wallet` を押すと、いまのアプリはホームに留まったまま
「ウォレットが無い状態」になります。ウォレット必須(#649)のもとで、この状態の
フレームは描かれていません(`10b` は `✕ NOT ADOPTED`)。

- **A.** `01 Welcome` に戻す(最初の接続画面をもう一度見せる)
- **B.** Account に留まり、行 3 が `Connect wallet` に変わる
- **C.** そもそも切断させない(`Disconnect wallet` を出さない)
- **D.** その他

---

### Q2 — Bluetooth 行の下にある「中継の注記」はどこへ行きますか?

いまの文面:「このスマホがイベント会場にいる間、beid はイベントの情報を近くの
スマホに中継することがあります。会場の反対側の人でもイベントを見つけられるように」。

このスマホが**他人のために電波を出している**という話なので、コード中のコメントは
「隠さず画面に出すべき物」として置かれています(`AccountSheetView.swift:75–77`)。
新デザインの 3 行構成には入る場所がありません。

- **A.** `15 About sensing` に移す
- **B.** `16 What we send` に移す
- **C.** Account の Bluetooth 行の下に小さく残す(4 行目相当の高さが増える)
- **D.** 消す(利用者に知らせない)
- **E.** その他

---

### Q3 — 過去のイベントへの再参加は、どこから行いますか?(**最優先**)

`Past events` は Figma のカンバス上に **1 フレームもありません**。
いまの Account の行が唯一の入り口なので、そのまま消すと
**コードを覚えていない人は昨日のイベントに戻れなくなります。**

- **A.** `08 Event Detail` に「再参加」を置く(`05e` の文面が
  「you can rejoin from the event page」と書いているので、これが一番近い)
- **B.** `04 Events (Home)` の一覧から直接再参加できるようにする
- **C.** `14 Organizer tools` と同じように Account に 4 行目を足す
- **D.** v1.0 では再参加をやめる(毎回コードを打つ)
- **E.** その他

---

### Q4 — フッターのビルド表記は、どの形にしますか?

- いまのアプリ: `1.0.0 (1234+374)` = 製品版数 + **git の高さ** + 配信ビルド番号
- 新デザイン: `SENSEPROOF 1.0 · 4C99036` = 製品名 + 版数 + 7 桁の文字列

git の高さは、**iOS のテスターと Android のテスターの報告が同じコミットの物か**を
突き合わせるために入れた数字です(#491)。`4C99036` に置き換えると、その用途は
失われます(コミット ID なら別の形で同じ事ができますが、Android 側と形が揃いません)。

なお製品名は **beid** です。`SENSEPROOF` はデザイン側の誤りとして
2026-09-22 に確認済みです。

- **A.** `beid 1.0 · 1234+374`(見た目は Flat 2b、中身はいまの情報を維持)
- **B.** `beid 1.0 · 4c99036`(コミット ID に変える。Android 側も揃える必要あり)
- **C.** `beid 1.0` だけ(突き合わせを諦める)
- **D.** その他

---

### Q5 — シートを閉じるボタンは残しますか?

Figma の `10` は掴み手だけで、`Done` がありません。
2026-07-27 に「ドラッグだけで閉じる形はアクセシビリティが落ちるので `Done` は残す」と
承認済みです(`docs/specs/account-redesign.md` §5.2)。

- **A.** 承認どおり `Done` を残す(Figma と見た目が変わる)
- **B.** 掴み手だけにする(2026-07-27 の決定を覆す)
- **C.** その他

---

### Q6 — `14 Organizer tools` の `Venue device` は、本当に出しますか?

`Venue device` は署名なしの旧方式(v1)です。**#597 で「会場の入り口は 2 つではなく
1 つ」と決めて、Account から外した物です。**画面のコードは残っていますが、
いまのアプリからは誰も辿り着けません。

新デザインの `14 Organizer tools` は `Venue device` / `Venue broadcast` / `VENUE KEY`
を並べているので、**#597 の決定を元に戻す形になります。**

- **A.** 意図どおり。v1 を復活させる(#597 を覆す)
- **B.** `14` からは外し、`Venue broadcast` と `VENUE KEY` だけにする
- **C.** その他

---

### Q7 — アドレスの書体は、見出しの書体ですか、等幅ですか?(#642 の受け入れ基準)

§5 に測った内容を書きました。選択肢はこの 2 つです。

**Figma はすでに見出しの書体で描いています**(ノード `208:46` を実測、§5.4)。
なのでこれは「決めてください」ではなく、**「そのままでよいか、上書きするか」**の確認です。

- **A. Figma のとおり(見出しの書体)** — `Display/Address 34`
  (Bricolage Grotesque ExtraBold 34pt、字間 −1%)。フレーム `10` が実際に
  使っているスタイルそのものです
- **B. 等幅に上書きする** — `Label/Mono 13 value`(DM Mono Medium 13pt)。
  ライブラリの表では「時刻・アドレス・ID の値」と説明されていますが、
  **Figma のフレーム上では観測されておらず、仕様書にしか存在しません**
- **C.** その他

判断材料をもう 2 つ。

1. **いまのアプリは等幅です**(`DS.Font.ledgerMono` = システム等幅の小さめサイズ)。
   A を選ぶと、字の種類が変わるだけでなく、文字の大きさが小さめの本文サイズから
   34pt の見出しサイズへ跳ねます。**見た目の変化としては、この文書の中で一番大きい部類です。**
2. **等幅を選ぶ場合は、§5.3 の三点リーダも一緒に決めてください。**
   等幅だと文字幅が揃うので、`...`(半角ピリオド 3 つ)と `…`(1 文字)で
   アドレスの表示幅が変わります。見出しの書体なら、どちらでもほぼ影響しません。

---

### 付記 — `CONNECTED VIA WALLETCONNECT` の文言について

これは質問ではなく、**すでに未決として記録済みの衝突**です
(`docs/decisions/issue-627-flat-2b.md` 未決事項 3、担当 issue に #642 を含む)。

`DESIGN.md` §15 は「ウォレットが**何をするか**を書き、プロトコルの名前は書かない」と
定めています。`WALLETCONNECT` はプロトコルの名前なので、この文言は
**まだ承認されていません**。

参考までに、**いまのアプリは `Connected via MetaMask`** と書いています
(ウォレットの製品名であって、プロトコル名ではない)。
§15 に照らすと、いまの文言のほうが近い位置にあります。
差し替え案が必要なら、この行も Q として立てられます。

---

## 5. Part 3 — アドレスの書体、測った内容

#642 の受け入れ基準「アドレスの書体が決まっている(§10-5: 見出し書体のままか等幅か)」の
判断材料です。**測り方も書きます。**

### 5.1 いまのアプリ

- 場所: `ios/Beid/Views/AccountSheetView.swift:23` → `.font(DS.Font.ledgerMono)`
- 定義: `ios/Beid/DesignSystem/Tokens.swift:195`
  `static let ledgerMono = SwiftUI.Font.system(.footnote, design: .monospaced)`
- 意味: **システム標準の等幅**(iOS では SF Mono)、大きさは本文より 2 段小さい
  「脚注」相当。トークンの説明は「台帳の痕跡: ウォレットアドレス、ハッシュ、
  証明の識別子」
- 同じトークンを使っている他の場所: `VenueSignedServingView.swift:175`, `:199`、
  `WalletConnectView.swift:252`
- 測り方: `git grep -rn 'ledgerMono' -- ios/`(5 件、うち 1 件が定義)

### 5.2 Flat 2b 側

`DESIGN.md:856`(Flat 2b の書体一覧)に、**この用途専用の行がすでにあります**:

```
| Display/Address 34 | Bricolage Grotesque ExtraBold | 34 | −1% | auto |
  Account sheet address (typeface open: spec §10-5, #642) |
```

つまり **Flat 2b の書体表は、いったん「見出しの書体」を割り当てたうえで、
「書体は未定」と但し書きを付けた状態**です。#642 はその但し書きを外す作業です。

対抗馬は同じ表の:

```
| Label/Mono 11 time · 13 value | DM Mono Medium | 11 / 13 | 0 | auto |
  Times, addresses, ID values (13 value: spec only, §0) |
```

説明文に「addresses」が入っています。ただし `docs/decisions/issue-627-flat-2b.md:65`
が、2026-09-22 の Figma 読み取りで **`Label/Mono 13 value` は観測されなかった
(仕様書にしか無い)** と記録しています。一方 `Display/Address 34` は
**観測されています**(同 `:59`)。

### 5.3 切り詰め方は、すでに一致しています

- いまのアプリ: `0x1234...5678`(先頭 6 文字 + 末尾 4 文字、
  `AccountSheetView.swift:219–224`)
- 新デザイン: `0x7aF3…9E2b`(SubPM 実測)= 先頭 6 文字 + 末尾 4 文字

**規則は同じです。**違うのは中黒の文字だけで、アプリは半角ピリオド 3 つ `...`、
Figma は三点リーダ 1 文字 `…` を使っています。等幅を選ぶ場合は、
どちらの文字を使うかで幅が変わるので、ついでに決めておくと実装が迷いません。

なお `docs/specs/account-redesign.md` §3.1(2026-07-27 承認)が
「`prefix(6)…suffix(4)` — 変更なし」と、すでにこの規則を承認済みです。

### 5.4 Figma のフレームが実際に使っている書体(実測)

フレーム `10` の中でアドレスを描いているテキストノード **`208:46`** を実測しました
(**SubPM 実測 (2026-09-23, Figma node `208:46`)**)。結果:

| 項目 | 値 |
|---|---|
| テキストスタイル | **`Flat 2b/Display/Address 34`** |
| 書体 | **Bricolage Grotesque ExtraBold**(ウェイト 800) |
| 大きさ | **34** |
| 行の高さ | 100 |
| 字間 | **−1**(実描画で −0.34px) |
| 可変フォントの軸 | `opsz 14` / `wdth 100` に固定 |

**つまり Figma は、等幅ではなく見出しの書体で描いています。**§5.2 で
「ライブラリに専用スタイルが存在し、書体だけ未定」と書いた状態は、フレーム側では
すでに `Display/Address 34` が当たっている、ということです。

`opsz 14` に固定されている点は `DECISIONS.md`(2026-09-23 [出来事]
「Flat 2b の Figma は可変フォントを opsz 14 固定で描いている」)に記録済みです。
#629 が同梱したフォントもその静的カットなので、**ここは測り直す必要がありません。**

**ただしこれは「Figma がそう描いている」という事実であって、決定ではありません。**
`DESIGN.md:856` の但し書き「typeface open: spec §10-5, #642」はまだ外れていません。
だから Q7 は **「Figma のとおりでよいか、それとも等幅に上書きするか」**という
確認の形にしてあります。デザイナーが意図して等幅を選ぶ余地は残っています。

---

## 6. issue #642 の本文・コメントとの食い違い

読んだ人が混乱しないように、全部並べます。
**どれも「誰かが間違えた」話ではなく、測った日が違う話です。**

### 6.1 本文の表について

| 本文の記述 | 実測 |
|---|---|
| 新デザインの 3 行は `Bluetooth` / **`How sensing works`** / `Disconnect wallet` | 3 行目まではそのとおりですが、2 行目は **`Organizer tools`** です(SubPM 実測 2026-09-23)。`How sensing works` はフレームにありません |
| いまある項目に「Venue device(会場発信 v1)」がある | **ありません。** #597 でこのシートから外されています(§2 R3) |
| Venue device / Venue serving は新デザインに **無い** | **あります。**`Organizer tools →` の 1 段下にまとめられています(§3) |
| 項目は 7 つ | 行は **8 つ**です。表が落としているのは `Leave Event`、`Version`、`Done`。表にあって実在しないのは `Venue device (v1)` と `How sensing works` |

### 6.2 新しいほうのコメントについて

コメントは「Figma の 10 は 7 行構成で、`Enter event code`・`What we send`・
`VENUE · ORGANIZER` への入り口を含む」と書いています。
**2026-09-23 時点のフレームは 3 行で、そのどれも含みません。**

これは書いた人の誤りではありません。**Figma が書き換わっています。**
`docs/decisions/issue-627-flat-2b.md:78–81` に、**2026-09-22 の**読み取り結果として
まさにその 7 行構成(`Bluetooth` / `Enter event code` / `How sensing works` /
`What we send`、`VENUE · ORGANIZER` の組、`Disconnect wallet`、フッター)が
記録されています。

つまりコメントは 2026-09-22 時点で正確で、**その翌日の改訂で古くなりました。**
同じ改訂でフレーム数も 22 → 45 に増えています(2026-09-22 の読み取りが 22、
SubPM 実測 2026-09-23 が 45。うち 2 つが `✕ NOT ADOPTED`、1 つが `DESIGN ONLY` なので
作るのは 42)。`DECISIONS.md` の 2026-09-23 の記録は「44 フレーム」と書いていますが、
実測は 45 です(差分は `05e Sensing — Stop confirm`)。

`docs/decisions/issue-627-flat-2b.md:41–42` が
「Figma はこのリポジトリで版管理していないので、あとで食い違ったら
**記憶で争うのではなく Figma の編集として辿れるようにしておく**」と書いています。
**その仕組みが、まさに今回それを果たしました。**

### 6.3 #648 の本文との食い違い

#648 の本文は「イベントコード画面への残りの入り口は Account と Scan」と書いて
いますが、実測では **Account からは繋がっていません**
(`04b` / `05a2` / `05d` の 3 つ、SubPM 実測)。#648 側の確認事項です。

### 6.4 `DESIGN.md` §1 との食い違い(**未解決**)

`DESIGN.md` §1 はいまも
「Wallet is optional … 一度も接続しない利用者にとっても筋が通って読めること」を
MUST として書いています。`docs/decisions/issue-627-flat-2b.md` の未決事項 2 が
これを「6 つ目の MUST 衝突」として記録し、担当 issue に #642 を挙げています。

一方 `DECISIONS.md` の 2026-09-22「ウォレット接続を必須にする」がこの MUST を
**覆すと決めています**(#649)。

**決定は出ているのに、`DESIGN.md` §1 の本文がまだ書き換わっていません。**
`DESIGN.md` §0 は「文書とコードが食い違ったら同じ変更で文書を直す」と定めているので、
#642 か #649 のどちらかで §1 を書き換える必要があります。
**この文書では直していません**(#642 の作業範囲外のため)。

---

## 7. ついでに見つけた小さい事(#642 の判断には影響しません)

- `Venue broadcast` という文言だけ、文字列カタログ
  (`ios/Beid/Localizable.xcstrings`、271 件)に登録されていません。
  他の行(`Bluetooth` / `Disconnect Wallet` / `Leave Event` / `Version` / `Done` /
  `Copy address` / `Active` / `Off`)は全部入っています。`DESIGN.md` §15 の
  「文字列カタログを通す」MUST に対する既存の抜けです。
- UI テストのコメント(`ios/BeidUITests/EventMembershipUITests.swift:35`)が
  「`Venue Device` より下の行」と書いていますが、その行はいま `Venue broadcast` です。
  #597 のときに直し忘れたコメントです。
- 新デザインの `16 What we send` に相当する画面は、いまのアプリにもあります
  (`TransparencyView`)。ただし入り口は Account ではなく、証明の詳細画面
  (`ItemDetailView.swift:147–160`)です。新デザインも `12 Report Detail` から
  繋いでいる(SubPM 実測)ので、**この点は既存の作りと新デザインが一致しています。**
