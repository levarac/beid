# beid#644 — いま iOS で動いている画面の棚卸しと、Flat 2b フレームとの対応

作成: 2026-09-23 / 対象コミット `e24f0d6` / ブランチ `work/issue-644-642-inventory`

この文書の読者はデザイナーです。**Xcode を開かずに決められる**ことだけを目指して
書いています。決めるのはデザイナーで、この文書は決めません。

---

## 0. 先に結論

iOS の画面・シート・警告・到達できる状態を **53 件**数えました。内訳:

| | 件数 |
|---|---|
| Flat 2b のフレームに対応するものがある(候補 1 件を含む) | 27 |
| **対応するフレームが無い**(#644 の本体) | 15 |
| フレーム名の一覧だけでは決められない(中身を見れば即決まる) | 7 |
| **フレーム以前に、いまのアプリで誰も到達できない** | 3 |
| 画面ではなく枠(`ScanFlowView` のタイトルと ✕) | 1 |

**対応するフレームが無い 15 件のうち、デザイナーの判断が要るのは実質 6 件**です。
残り 9 件は開発側で処理できるもの(デバッグ専用のボタン、技術的な警告など)です。

判断が要る 6 件:

1. **Today(その日の記録)** — `DailySummaryView`
2. **Past events(過去のイベント)** — `PastEventsView`
3. **Transparency(何を送ったか)** — `TransparencyView`
4. **参加サマリー** — `ParticipationSummaryView`
5. **セッション一覧** — `SessionParticipationListView`
6. **Account の「Join Event」** — イベントコード入力への入り口

質問はすべて **§7 に一覧**にしてあります。§7 だけ読んで答えられるように書きました。

そして **3 件の、issue の前提と食い違う実測結果**があります(§6)。とくに:

- **Venue device (v1) は、いまのアプリで誰も到達できません。** #644 の表と #647 の表は
  どちらも「あり / 到達できる」と書いていますが、コードとしてあるだけです。
- **オンボーディングのウォレット接続画面も、誰も到達できません。** #648 の「3 箇所から
  入る」は、いま実際には 2 箇所です。

---

## 1. どうやって数えたか(再現できます)

数え方そのものを疑えるように、実際に使ったコマンドを置きます。すべて
`/Users/ko/Workspace/levarac/beid-worktrees/issue-644-inventory` で実行しました。

### 1.1 ディレクトリを絞らない

`ios/Beid/Views/` だけを見ると、画面の半分を取りこぼします。根っこの画面切り替えは
`ios/Beid/Navigation/` にあり、警告は `ios/Beid/Sensing/` に文言があります。
対象にしたのは `ios/Beid/` 配下の Swift ファイル **全 98 件**です。

```
find ios/Beid -name '*.swift' | wc -l      # → 98
find ios/Beid -name '*.swift' | sort       # 一覧
```

内訳は `Views` 28 / `Sensing` 28 / `Persistence` 19 / `Models` 10 / `App` 4 /
`Onboarding` 3 / `Navigation` 3 / `DesignSystem` 2 / 直下 1 です
(`find ios/Beid -name '*.swift' | sed 's|/[^/]*$||' | sort | uniq -c` で出ます)。
98 件すべてを画面の観点で確認し、うち画面・状態を持つものを §2 以降に展開しています。

### 1.2 画面を出す仕組みを全部探す

SwiftUI で新しい画面が出る方法は 7 通りあります。7 通りすべてを検索しました。

```
for p in '\.sheet\(' '\.fullScreenCover\(' '\.alert\(' '\.confirmationDialog\(' \
         'NavigationLink' 'navigationDestination' '\.popover\('; do
  echo "### $p"
  git grep -nP "$p" -- 'ios/Beid/**/*.swift' 'ios/Beid/*.swift'
done
```

結果です。**単位を混ぜると読み間違えるので、3 つに分けて出します。**
「箇所」は一致した行数、「ファイル」はそのファイル数、「実コード」は箇所のうち
コメント行を除いたもの —— つまり**実際に画面を出している場所の数**です。

| 仕組み | 箇所 | ファイル | 実コード |
|---|---|---|---|
| `.sheet(` | 6 | 4 | **5** |
| `.fullScreenCover(` | 1 | 1 | **1** |
| `.alert(` | 2 | 1 | **2** |
| `.confirmationDialog(` | 0 | 0 | **0** |
| `NavigationLink` | 10 | 6 | **6** |
| `navigationDestination` | 2 | 1 | **2** |
| `.popover(` | 0 | 0 | **0** |

`.sheet` の 6 と 5 の差、`NavigationLink` の 10 と 6 の差は、どちらも**コメントの中に
その語が出てくる**ためです(例: `AccountSheetView.swift:152` は `.sheet(isPresented:)`
の挙動を説明した注釈)。数えるときにコメントを外さないと、実際より多く見えます。
右端の「実コード」列だけが、画面が出る場所の数です。

再現するには:

```
git grep -nP '\.sheet\(' -- 'ios/Beid/**/*.swift' 'ios/Beid/*.swift' | wc -l   # 箇所
git grep -lP '\.sheet\(' -- 'ios/Beid/**/*.swift' 'ios/Beid/*.swift' | wc -l   # ファイル
git grep -nP '\.sheet\(' -- 'ios/Beid/**/*.swift' 'ios/Beid/*.swift' \
  | grep -vP '^[^:]+:\d+:\s*(//|\*)' | wc -l                                  # 実コード
```

> `.confirmationDialog` が 0 件だったことは、それ自体が答えです。
> **いまの iOS には確認ダイアログが 1 つもありません。**
> 「Disconnect wallet」も「Stop sensing」も、押した瞬間に実行されます。
> Flat 2b の `10d Account — Disconnect confirm` と `05e Sensing — Stop confirm` は
> どちらも**新規に作るもの**で、既存画面の置き換えではありません。

### 1.3 両方向から突き合わせる

片方向だけだと「呼ばれていない画面」を見逃します。両方向でやりました。

- **画面 → 呼び出し元**: 各 `View` 型について、自分のファイル以外からの生成箇所を数える
- **呼び出し元 → 画面**: 画面切り替えの全代入を列挙する

```
git grep -nP 'screen\s*=\s*\.' -- 'ios/Beid/**/*.swift'
git grep -hoP '^\s*(?:private\s+)?struct\s+\K\w+(?=[^{]*:\s*(?:View|ViewModifier|UIViewControllerRepresentable))' \
  -- 'ios/Beid/**/*.swift' 'ios/Beid/*.swift' | sort -u
```

これで **`VenueDeviceOrganizerView`(Venue device v1)の生成箇所が 0 件**だと
分かりました(§6.1)。

### 1.4 このホストの落とし穴 — `git grep -E` は `\b` を黙って無視する

これは数え間違いを起こす罠なので明記します。**`git grep -E` に `\b`(単語の境界)を
書くと、このホストでは一致が 0 件になり、エラーも警告も出ません。**
「0 件だった = 存在しない」と信じてしまいます。`grep -E` の方は正しく動くので、
試しに動かして確認した人ほど騙されます(beid の DECISIONS.md 2026-09-23 に記録あり)。

実際に確かめました:

```
git grep -cE '\bstruct\b' -- 'ios/Beid/Views/*.swift'   # → 何も出ない(0 件)
git grep -cP '\bstruct\b' -- 'ios/Beid/Views/*.swift'   # → 28 ファイル分が出る
```

**この文書に書いた数字はすべて `git grep -P` で数えています。**

### 1.5 Flat 2b 側の数字の出どころ

フレームの一覧、フレーム 10 の中身、どのフレームからどのフレームへ行くかは、
**SubPM 実測(2026-09-23, Figma `183:2`)** です。この文書の作成者は Figma を
開いていません。

- ファイル `xf2uFHceIYg0h0gJndUkmI`、キャンバス `183:2`「Flat 2b — Screens」
- **最上位フレーム 45 枚**(44 枚ではありません。差分は `05e Sensing — Stop confirm`)
- うち `01b` と `10b` が `✕ NOT ADOPTED`、`05c` が `DESIGN ONLY`
- **したがって作るのは 42 枚**

---

## 2. 対応するフレームが無いもの — #644 の本体

ここが判断の対象です。**「消したら、誰が、どんなときに、何ができなくなるか」**を
具体的に書きました。

### 2.1 デザイナーの判断が要る 6 件

---

#### (1) Today — その日の記録

| | |
|---|---|
| コード | `ios/Beid/Views/DailySummaryView.swift` / `DailySummaryView` |
| 画面上の文字 | 見出し `Today` / 空のとき `No proofs yet today` + `Proofs you collect today will show up here.` / 記録があるとき `N proofs collected today` |
| 入り方 | ホーム(`04 Events`)の**左上のカレンダーアイコン**。読み上げラベルは `Today`。条件なしで常に押せる |
| Flat 2b | **なし**。`Today` `Daily` `Calendar` はキャンバス上に **0 回**(SubPM 実測) |

**消すと失われるもの:** 今日というくくりで記録を見る唯一の場所です。ホームのグリッドは
**イベント単位**にまとめられています(同じイベントで 2 回記録しても 1 枚)。
1 日に複数のイベントを回った参加者 —— カンファレンスで午前のセッションと
夕方のミートアップに出た人 —— が「今日は何を拾ったか」を確認する手段が無くなります。

この画面にはもう 1 つ、他のどこにも無い情報があります。**送信機能が有効かどうかの表示**です
(`Sending isn't turned on for this build.` / `Not sent yet.`)。いまの出荷ビルドでは
送信はオフなので、常に前者が出ます。これも同時に消えます。

---

#### (2) Past events — 過去のイベントに入り直す

| | |
|---|---|
| コード | `ios/Beid/Views/PastEventsView.swift` / `PastEventsView` |
| 画面上の文字 | 見出し `Past Events` / 空のとき `No past events yet.` / 脚注 `Only events you've actually recorded a proof for are listed here.` |
| 入り方 | ホーム右上の人アイコン → Account シート → `Past Events` の行(押すと右から入る) |
| Flat 2b | **なし**。`Past events` はキャンバス上に **0 回**(SubPM 実測) |

**消すと失われるもの:** **コードを打ち直さずに同じイベントへ入り直す**唯一の方法です。
イベントコードは 64 文字あります(#648)。1 日目に参加した人が 2 日目に戻るとき、
この行が無ければ 64 文字を手で打ち直すことになります。

**候補があります(§7 Q2 で「はい / いいえ」で答えられます)。**

`05e Sensing — Stop confirm` の本文にこう書かれています(SubPM 実測):

> "What you've recorded so far is sealed and kept on this phone. Sensing for this
> event ends now — **you can rejoin from the event page**."

「the event page」は `08 Event Detail` のことだと読めます。つまり**新デザインは
すでに「入り直しはイベント詳細から」と言っている**ことになります。
であれば、いまの `PastEventsView` の行き先は `08 Event Detail` です。

ただし 1 つだけ差があります。`PastEventsView` は**過去のイベントの一覧**で、
`08 Event Detail` は**1 つのイベント**です。一覧から選ぶ動線がホーム(`04 Events`)の
グリッドで代わりになるかどうかは、グリッドに過去のイベントが全部並ぶかによります。

---

#### (3) Transparency — 自分のデータが今どこにあるか

| | |
|---|---|
| コード | `ios/Beid/Views/TransparencyView.swift` / `TransparencyView` |
| 画面上の文字 | 見出し `Transparency` / 3 段構成 `Participation`(`Joined`)、`Participation record`、`Verified proof` |
| 入り方 | ホームのカード → Proof 詳細 → `Transparency` の行 |
| Flat 2b | **なし**。`Transparency` はキャンバス上に **0 回**(SubPM 実測) |

**消すと失われるもの:** 参加者が**自分のデータの行き先を確認できる唯一の画面**です。
6 つの行があり、それぞれ「まだありません」か実際の数字を出します:

- `Mutual observation`(相手も自分を観測したか)— 常に「まだありません」
- `Recorded on device`(端末に記録済み)— 実数
- `Not submittable (count-only record)`(送れない記録)— 実数
- `Sent`(送信済み)— 実数または「まだありません」
- `Acceptance receipt`(受領確認)— 同上
- `Included in published data`(公開データに入ったか)— 常に「まだありません」

**候補があります(§7 Q3)。** `16 What we send`(送信内容の開示、スクロールする画面)が
中身として最も近いです。ただし `16` の入り口は `12 Report Detail` と
`15 About sensing` の中で、**Account からも Proof 詳細からも入れません**(SubPM 実測)。
いま Proof 詳細から入っているものを `16` に畳むなら、`09 Proof Detail` から `16` への
線を 1 本足す必要があります。

---

#### (4)(5) 参加サマリー と セッション一覧

| | |
|---|---|
| コード | `ios/Beid/Views/ParticipationSummaryView.swift` / `ios/Beid/Views/SessionParticipationListView.swift` |
| 画面上の文字 | どちらも見出し `Participation summary`。一覧側は `N sessions recorded for this event` / 内訳は `Band 1: 3 devices sensed` の形 |
| 入り方 | Proof 詳細 → `View participation summary` の行。**同じイベントを 2 回以上記録していれば一覧、1 回なら直接サマリー** |
| Flat 2b | **なし**。`Summary` `Participation` はキャンバス上に **0 回**(SubPM 実測) |

**消すと失われるもの:** 1 回の記録セッションについて、**時間帯ごとに何台の端末が
いたか**を見る唯一の場所です(`Band 1: 3 devices sensed` の並び)。

そして**セッション一覧の方が重要です。** 同じイベントに 2 回参加した場合、
ホームのカードは 1 枚にまとまります。その 2 回それぞれの中身に分けて辿れるのは
この一覧だけです。これが無いと、2 回分が 1 枚のカードの裏に隠れたまま、
片方しか見えない状態になります(これは過去に一度直した問題です — beid#217)。

**候補があります(§7 Q4)。** `11 Observation Detail` が中身として近いです。

---

#### (6) Account の「Join Event」— イベントコード入力への入り口

| | |
|---|---|
| コード | `ios/Beid/Views/AccountSheetView.swift`(`EventMembershipSections`)→ `EventCodeEntryView(mode: .accountSheet)` |
| 画面上の文字 | 行のラベル `Join Event`。開いた先は `Enter Event Code` |
| 入り方 | Account シート → `Join Event` の行。**すでにイベントに参加中は押せません** |
| Flat 2b | **なし**。`Join Event` はキャンバス上に **0 回**(SubPM 実測) |

**消すと失われるもの:** 実は**ほとんど何も失われません。** Scan 画面(`05a`)の
下部に同じ入り口があり、新デザインでは `04b Events — Empty`、
`05a2 Sensing — Detecting (20 s+)`、`05d Sensing — Can't join` の 3 箇所から
入れます(SubPM 実測)。Account から入る必要はもう無い、という読み方ができます。

ここは**矛盾の報告として**挙げています。#648 の本文は「残るのは Account と Scan」と
書いていますが、実測した Flat 2b の動線に **Account は含まれていません**(§6.3)。

---

### 2.2 開発側で処理でき、デザイナーの判断が要らない 9 件

記録のために列挙します。「消してよいか」を聞いているのではなく、
**「これは画面ではないので数に入れないでください」**という意味です。

| # | もの | 入り方 | なぜ判断不要か |
|---|---|---|---|
| 7 | `BluetoothDeniedView`「Bluetooth permission required」 | Bluetooth の許可を**拒否**したとき | `03 Bluetooth Off` は「電源が入っていない」状態で、これは「拒否された」状態。別物だが、**新デザインに拒否状態のフレームが無い**のは事実。→ §7 Q5 |
| 8 | Scan 画面の「Some nearby events are not shown.」 | 近くのイベントが 32 件を超えたとき | 一覧が全部ではないことの注記。`05a` の中の 1 行として扱えばよい |
| 9 | 記録中の「Diagnostics: N identified · M unidentified」 | 記録中、常時表示 | 現地測定用の一時的な行。**出荷ビルドにも出ています**が、恒久的な UI ではない(beid#218) |
| 10 | 「Simulate Signal Lost」ボタン | **DEBUG ビルドのデモモードのみ** | デバッグ専用。Android の同種ボタンは撤去が決定済み(2026-09-22) |
| 11 | 「Simulate binding (Demo)」ボタン | **DEBUG ビルドのデモモードのみ** | 同上 |
| 12 | Account の「Leave Event」の行 | Account シート、参加中のみ押せる | **撤去が決定済み**(2026-09-23、CLOSE に統一) |
| 13 | 「Proof identity was reset」ほか 3 種の警告 | 端末の鍵が読めなくなったとき、起動直後に | 技術的な異常時の警告。Flat 2b に対応が無いが、出さないわけにいかない。→ §7 Q6 |
| 14 | 「Proof key is unavailable」の警告 | 鍵にアクセスできないとき | 同上 |
| 15 | `ScanFlowView` の枠(タイトル `Scan` と ✕) | Scan を開いている間ずっと | 枠であって画面ではない |

---

## 3. 対応するフレームがあるもの(27 件)

確認のための一覧です。ここは読み飛ばして構いません。

### 3.1 オンボーディング

| コード | 画面上の文字 | 入り方 | フレーム |
|---|---|---|---|
| `WelcomeView` | `beid` / `Prove you were there. Automatically.` / `Get Started` | 初回起動 | **01** |
| `BluetoothPermissionView` | `Enable Bluetooth` / `beid senses nearby events and people over Bluetooth Low Energy — that's how it proves you were really there.` / `Allow Bluetooth` | `Get Started` を押した直後 | **02** |
| `BluetoothOffView` | `Bluetooth is off` / `beid can't sense events or collect proofs while Bluetooth is off.` + 3 手順 + `I've turned it on` | 許可済みだが電源オフのとき | **03** |

### 3.2 ホーム

| コード | 画面上の文字 | 入り方 | フレーム |
|---|---|---|---|
| `CollectionHomeView` | タイトル `Collection` / `Proof collected from N events` | 許可が通った後の既定画面 | **04** |
| 同・空状態 | `No proofs yet` / `Start sensing at an event to collect your first proof.` / `Sense Event` | 記録が 1 件も無いとき | **04b** |

### 3.3 Scan(ホーム下部の丸いボタンから全画面で開く)

| コード | 画面上の文字 | 入り方 | フレーム |
|---|---|---|---|
| `SensingView` | `Sensing automatically` / `Walk into an event — it will show up here automatically.` | Scan を開いた直後 | **05 / 05a** |
| 同・近くのイベント一覧 | `Nearby events` / `Searching for nearby events…` / `If no event appears, enter the event code instead.` | 参加前のみ表示 | **05a** |
| 同・参加を断られた通知 | 5 種類。例: `beid needs a connection to verify this event, and couldn't reach the network. Check your connection and try again.` | 参加が拒否されたとき(**本番の経路です**) | **05d** |
| `ClockPreflightNoticeView` | `This device's clock is off` / `Couldn't check this device's clock` + `Check again` | Scan を開くたびに自動で確認 | **04c** ※置き場所が違う(§6.4) |
| `EventCodeEntryView(.scanFlow)` | `Enter Event Code` / `e.g. ETHTOKYO2026` / `Join Event` | Scan 画面の下部 `Enter event code` | **13 / 13b** |
| `EventFoundView` | `Event Found` / `Verification starts automatically — stay nearby` | イベントを検出したとき | **05b**(候補) |
| `RecordingView` 入場演出 | `Proof Collected` / `Added to your collection.` | 記録が始まった瞬間に 1 回だけ、2 秒 | **07** |
| `SignalLostView` | `Signal Lost` / `beid lost the connection to <名前>. Move closer and we'll pick it back up automatically.` / `Try Again` | **DEBUG のデモ経路のみ**(§6.5) | **05c**(DESIGN ONLY) |
| `EventBindingSheetView` 成功 | `Sealed` / `Your attendance to <名前> is sealed.` | ウォレット署名が通ったとき | **06** |

### 3.4 Account(ホーム右上の人アイコン)

| コード | 画面上の文字 | 入り方 | フレーム |
|---|---|---|---|
| `AccountSheetView` | タイトル `Account` / `Done` | ホーム右上 | **10** |
| ウォレット行(接続済み) | 短縮アドレス + `Connected via MetaMask` + コピーボタン | ウォレット接続済みのとき | **10 / 10e** |
| Bluetooth 行 | `Bluetooth` + 点 + `Active` / `Off`、脚注に中継の説明 | 常時 | **10 / 10c** |
| `Disconnect Wallet` | 赤い行 | 接続済みのときのみ押せる | **10**(確認 **10d** は未実装) |
| `Version` 行 | `1.0.0 (1234+374)` の形 | 常時 | **10** の脚注 |
| `Venue broadcast` 行 | `Venue broadcast` | Account シート | **14b** ※経路が違う(§6.2) |

### 3.5 Proof 詳細

| コード | 画面上の文字 | 入り方 | フレーム |
|---|---|---|---|
| `ItemDetailView` | タイトル `Proof Detail` / `Method` / `Devices sensed` / `Status: Recorded on device` | ホームのカードを押す | **08 / 09**(分かれる可能性、§7 Q7) |

### 3.6 Venue(会場側)

| コード | 画面上の文字 | 入り方 | フレーム |
|---|---|---|---|
| `VenueSignedServingView` | タイトル `Venue broadcast` / `This event` / `No pack yet.` / `Paste the link the organiser gave you, or scan its QR code.` | Account → `Venue broadcast` | **14b** |
| `VenueLinkScannerView` | タイトル `Scan QR code` / `Cancel` | 上の画面の `Scan QR code` | **14d** |
| カメラ拒否・制限・起動失敗 | `This device cannot scan QR codes. Paste the link instead.` ほか | カメラが使えないとき | **14f / 14f2 / 14f3** |
| リンクが受け付けられない 3 種 | 入力欄のすぐ下に 1 文 | 不正なリンクを貼ったとき | **14e / 14e2 / 14e3** |
| pack 保存失敗 | `This pack could not be saved. It stays on this device only until the app closes.` | 保存に失敗したとき | **14g** |

---

## 4. フレーム名の一覧だけでは決まらないもの(確認 8 件)

**Figma を開いているデザイナーなら数秒で答えられます。** 「このフレームの中に
この要素はありますか」という確認です。8 件のうち (h) だけは候補が立っているので、
合っているかどうかの確認です(残り 7 件は候補なし)。

| # | もの | 画面上の文字 | 聞きたいこと |
|---|---|---|---|
| a | ホームの探索中バナー | `Sensing continues in background` + `Stop sensing` | `04 Events` の中にありますか |
| b | 記録中の定常表示 | `Recording your attendance automatically · N devices sensed` + `N windows recorded` | `06 Sensing — Sealed` の中ですか、別の状態ですか |
| c | ウォレット署名の依頼 | `<イベント名> confirmed` / `Connect a wallet to seal your attendance to this event.` | `06` の手前の状態としてありますか |
| d | ウォレット署名の失敗 | `Couldn't seal attendance` / `beid couldn't finish sealing your attendance with this wallet.` + `Try Again` | フレームがありますか |
| e | Account の中継の脚注 | `While this phone is at an event, beid can pass the event's details on to phones nearby, so people across the venue can still find it.` | `10` の中にありますか |
| f | Account からのウォレット接続シート | タイトル `Connect Wallet` + `Cancel` | ウォレット必須になった後、接続はどこで行いますか(§6.6 と関係) |
| g | ウォレット未接続の Account | `Connect Wallet` の行 | `10b` は NOT ADOPTED。**ウォレット必須なら、この状態は存在しなくなる**という理解で合っていますか |
| h | イベント検出 `Event Found` | `Event Found` | `05b Sensing — Connecting` と同じものですか |

---

## 5. この数え方が取りこぼすもの

**この文書が見落としている可能性がある場所を、具体的に挙げます。**
「完全なつもりの一覧が後から足りないと分かる」ことを、このリポジトリは何度も
経験しています。

1. **実行時にしか現れない分岐。** 状態の組み合わせが特定の値になったときだけ出る
   文言は、コードを読むだけでは見つかりません。とくに `VenueSignedServingView` は
   8 種類の状態を切り替えており、うち 4 種類はさらに内側で分岐します。
   **§3.6 の Venue の行は「代表的な文言」であって、全 30 種類の網羅ではありません**
   (全 30 種類は #647 の本文にあります)。

2. **OS が出すもの。** Bluetooth の許可ダイアログ、カメラの許可ダイアログ、
   設定アプリへの遷移は iOS 自身が出すので、この一覧に入っていません。
   Flat 2b にも対応するフレームは要らないはずですが、**参加者から見れば画面です**。

3. **文字列カタログだけにある文言。** `String(localized:)` の `defaultValue` を
   引用しましたが、翻訳カタログ(`.xcstrings`)側の英語が **`defaultValue` より優先される**
   ケースが実際にありました(`Serving until` → `Broadcasting until` の件、beid#599)。
   **この文書の英文は、画面に出る文字と 1 文字違う可能性があります。**
   正確さが要る箇所は実機で確認してください。

4. **`EventCardView` / `BeidStatusPill` などの部品の状態。** 部品として数えており、
   独立した画面としては数えていません。`EventCardView` には
   `detected` / `recording` / `paused` の 3 つのバッジがあります。

5. **読んでいない `if`。** 各画面の内部の条件分岐は、`.sheet` などの
   「画面を出す仕組み」からは辿れません。§1.2 の 7 パターンに現れない形で
   内容が大きく変わる場所があれば、取りこぼしています。

6. **iPad のレイアウト差。** `BeidAdaptiveContent` によって横幅の広い端末では
   レイアウトが変わりますが、別画面としては数えていません。

---

## 6. issue の前提と食い違った実測結果

**どれも「issue にこう書いてあるが、コードはそうなっていない」という報告です。**

### 6.1 Venue device (v1) は、いま誰も到達できない — 確認済み

**#644 の表と #647 の表が、どちらも事実と違います。**

- #644 の表は Venue device を「**現在の iOS で動いていて、利用者が到達できる**」画面として
  挙げています。
- #647 の表は `14a Venue device (v1)` の現状を「**あり(`VenueDeviceOrganizerView`)**」と
  書いています。

実測(独立に確認しました):

```
git grep -Pn "([^A-Za-z0-9_]|^)VenueDeviceOrganizerView([^A-Za-z0-9_]|$)" -- 'ios/'
```

`project.pbxproj`(ビルド設定)を除くと、返るのは 6 行だけです。

- `ios/Beid/Views/VenueDeviceOrganizerView.swift:20` — 型の定義
- `ios/Beid/Views/VenueDeviceOrganizerView.swift:178` と `:184` — **どちらも同じファイル内の
  `#Preview` ブロックの中**(Xcode のプレビュー専用。アプリには出ません)
- 残り 3 行 — 他のファイルのコメント

**つまり、アプリ本体からこの画面を開くコードは 1 行も存在しません。**

理由もコードに書いてあります。`ios/Beid/Views/AccountSheetView.swift:82-88`:

> "One venue entry, not two (beid#597). ... The unsigned v1 row (gh#138) is
> **withdrawn from this sheet** rather than deleted: `VenueDeviceOrganizerView` and its
> view model are untouched, so restoring it is one NavigationLink if dispatch#4
> decides it ships."

**beid#597 が意図的に Account シートから外しました。** 消さずに残してあるのは、
dispatch#4 が「出す」と決めたら 1 行で戻せるようにするためです。

**デザイナーに知っておいてほしい帰結:**
新しい `14 Organizer tools` のフレームには `Venue device` の行があります(SubPM 実測)。
つまり**再デザインは、#597 が意図的に外した行を復活させることになります。**
これが意図した選択なのかどうかは、§7 Q8 で聞いています。

### 6.2 Venue broadcast への経路が、いまと新デザインで違う

- **いま:** Account シートに `Venue broadcast` の行が**直接**あり、押すとその画面に入ります。
  間に何もありません。
- **Flat 2b:** Account シートの行は `Organizer tools →` で、そこから `14` に入り、
  `14` が `Venue device` / `Venue broadcast` / `VENUE KEY` を並べます(SubPM 実測)。

つまり**階層が 1 段増えます。** 現状を「行が 2 つ並んでいるだけ」と書いている #647 の
記述は、**#597 以降は行が 1 つです**(§6.1 の通り、もう 1 つは外されています)。

### 6.3 イベントコード入力の入り口は、#648 が書いている 3 箇所ではない

#648 の本文:

> iOS は **3 箇所から同じ画面**に入る(オンボーディング / Account / Scan)。
> ウォレット必須の判断により、オンボーディングの経路は撤去されるので、
> **残るのは Account と Scan**。

**両側とも違います。**

**いま(実測):入り口は 2 箇所で、3 箇所ではありません。**
オンボーディングの経路は**すでに到達不能**です(§6.6)。実際に動くのは
Account と Scan の 2 つです。

**新デザイン(SubPM 実測):Account は入り口ではありません。**
`13 Enter Event Code` へ入るのは `04b Events — Empty`、
`05a2 Sensing — Detecting (20 s+)`、`05d Sensing — Can't join` の 3 箇所です。
(`01b` にもありますが NOT ADOPTED。)

### 6.4 時計ずれの警告は、いま Scan 画面に出る。フレームはホームにある

`04c Events — Clock warning` はホーム(Events)のフレームです。
いまの実装では、この警告は **Scan 画面の参加前の状態**に出ます
(`ios/Beid/Views/SensingView.swift:141`、`isPreJoin` のときだけ)。
ホームには出ません。

また `AppCoordinator.startScan()` は **Scan を開くたびに**確認し、
近くのイベントのカードを押した瞬間にも**もう一度**確認します。
つまり「時計が狂っている」と気づくのは参加しようとした時点であって、
ホームを見ている時点ではありません。**置き場所が変わることになります。**

### 6.5 Signal lost の実測 —— 決定と一致します(矛盾ではありません)

確認しました。**`.signalLost` の状態に入るコードは 2 箇所だけで、どちらもデモ経路です。**

- `SensingCoordinator.simulateSignalLost()` — 呼ぶのは `RecordingView` の
  「Simulate Signal Lost」ボタン 1 つだけで、そのボタンは `#if DEBUG` と
  `useDemoEventMode` の**二重に囲われています**
- デモ台本の `.simulateSignalLost` ステップ

`useDemoEventMode` は出荷ビルドでは**常に `false` を返す実装**です
(`ios/Beid/Sensing/SensingCoordinator.swift:928`、Release では getter が `false` 固定)。
シミュレータか、`-beid-demo-event` を付けて起動した開発端末でのみ `true` になります。

**実際の電波断を検出するコードはありません。** これは DECISIONS.md 2026-09-22 の
「Signal lost の検出実装は見送る」と完全に一致します。矛盾はありません。

### 6.6 ウォレット接続の画面も、いま誰も到達できない

**これはウォレット必須の決定(2026-09-22)の前提に関わります。**

DECISIONS.md 2026-09-22 は、影響範囲を
「iOS のオンボーディングの『Enter event code instead』、Account の『Join Event』」と
書いています。しかし**前者はすでに動いていません。**

実測。画面の切り替えは 7 つの状態を持ち、`.walletConnect` に入る代入は 2 箇所だけです。

1. `AppCoordinator.swift:153` — `beginOnboarding()` の `.walletFirst` の分岐。
   ただし `OnboardingMode.current` は **`.guestFirst` に固定**されています
   (`ios/Beid/Models/OnboardingMode.swift:19`)。**この分岐は通りません。**
2. `AppCoordinator.swift:199` — `returnToWalletConnect()`。これを呼ぶのは
   `EventCodeEntryView` の「Connect wallet instead」ボタンだけで、そのボタンは
   `.eventCodeEntry` の画面にしか出ません。そして `.eventCodeEntry` に入るのは
   `skipWalletForEventCode()` だけで、それを呼ぶのは `WalletConnectView` だけです。

**閉じた輪になっています。** どちらの入り口も、すでにその中にいないと入れません。

**帰結:**

- **オンボーディングにウォレット接続の段階は存在しません。** いまの起動直後の流れは
  `01 Welcome` → `02 Enable Bluetooth` → `04 Events` です。
- いまウォレットを繋げる場所は **2 つだけ**です:
  (a) Account シートの `Connect Wallet`、
  (b) 記録が始まった直後に自動で出る署名シート(`EventBindingSheetView`)。
- したがって**ウォレット必須にするには、「経路を撤去する」のではなく
  「オンボーディングにウォレットの段階を新しく作る」ことになります。**
  `01b Welcome — Wallet optional` は NOT ADOPTED なので、
  **どのフレームがその段階にあたるのかが、現時点で決まっていません。** → §7 Q1

---

## 7. デザイナーへの質問(これだけ読めば答えられます)

**Q1. ウォレット接続はどの画面で行いますか。**
いまオンボーディングにウォレットの段階はありません(§6.6)。必須にすると、
新しく作ることになります。
- (a) `01 Welcome` の後に新しいフレームを足す
- (b) 既存のどれかのフレームを使う(→ どれですか)
- (c) オンボーディングでは繋がず、イベント参加時の署名シートだけで繋ぐ

**Q2. `Past Events`(過去のイベントに入り直す)は `08 Event Detail` に畳みますか。**
`05e` の本文が「you can rejoin from the event page」と言っているので、そう読めます。
- (a) はい、`08 Event Detail` に畳む
- (b) いいえ、一覧として別に残す
- (c) 入り直し自体を無くす

**Q3. `Transparency`(何を送ったか)は `16 What we send` に畳みますか。**
畳む場合、`09 Proof Detail` から `16` への線が 1 本要ります(いまの `16` の入り口は
`12 Report Detail` と `15 About sensing` だけです)。
- (a) はい、畳む。`09` → `16` の線を足す
- (b) はい、畳む。`09` からは入れなくてよい
- (c) いいえ、別に残す

**Q4. 参加サマリーとセッション一覧は `11 Observation Detail` に畳みますか。**
同じイベントに 2 回以上参加したとき、回ごとに分けて辿れる必要があります。
- (a) はい、`11` に畳む。複数回の分岐も `11` で扱う
- (b) はい、`11` に畳む。複数回は考えなくてよい
- (c) いいえ、別に残す

**Q5. `Today`(その日の記録)はどうしますか。**
- (a) 無くす
- (b) `04 Events` の中の絞り込みとして残す
- (c) 別のフレームとして残す(→ 新規に作る)

**Q6. Bluetooth を「拒否」されたときの画面はどれですか。**
`03 Bluetooth Off` は「電源が入っていない」状態です。「許可を拒否された」状態は
別で、いまは別画面(`Bluetooth permission required`)があります。
- (a) `03` に統合する
- (b) 新しいフレームを作る
- (c) いまのまま英文だけ Flat 2b に揃える

**Q7. 鍵の異常を知らせる警告 4 種は、Flat 2b でどう出しますか。**
「Proof identity was reset」など、端末の鍵が読めなくなったときに起動直後に出ます。
頻度は低いですが、出さないわけにいきません。
- (a) いまのまま OS 標準の警告ダイアログ
- (b) Flat 2b の見た目に合わせた新しいフレームを作る

**Q8. `14 Organizer tools` の `Venue device` の行は、意図した復活ですか。**
beid#597 がこの行を Account から**意図的に外しました**(「pack の中身が署名されて
いるかどうかは、会場の人に選ばせることではなく、機能の仕組みだ」)。
いまは誰も到達できません(§6.1)。新デザインはこれを復活させることになります。
- (a) はい、意図的に戻す
- (b) いいえ、`14` から `Venue device` の行を外す
- (c) #597 の判断を知らなかったので、検討し直す

**Q9. `ItemDetailView` は `08 Event Detail` と `09 Proof Detail` に分かれますか。**
いまは 1 つの画面です。イベント単位でまとめた内容(`08` 寄り)を持ちながら、
タイトルは `Proof Detail`(`09`)です。
- (a) 2 つに分かれる
- (b) `09` 1 つになる
- (c) `08` 1 つになる

**Q10. §4 の 8 件 —— Figma を開いて「そのフレームの中にありますか」だけ教えてください。**

---

## 付録: 数えた 53 件の全一覧

| # | コード | フレーム | 備考 |
|---|---|---|---|
| 1 | `WelcomeView` | 01 | |
| 2 | `WalletConnectView` | — | **到達不能**(§6.6) |
| 3 | `EventCodeEntryView(.onboarding)` | — | **到達不能**(§6.6) |
| 4 | `BluetoothPermissionView` | 02 | |
| 5 | `BluetoothDeniedView` | なし | Q6 |
| 6 | `BluetoothOffView` | 03 | |
| 7 | `CollectionHomeView` | 04 | |
| 8 | 同・空状態 | 04b | |
| 9 | 同・件数キャプション | 04 | |
| 10 | `ContinuousSensingStatus` | 要確認 | §4-a |
| 11 | `ScanFlowView` の枠 | — | 枠 |
| 12 | `SensingView` | 05 / 05a | |
| 13 | 同・近くのイベント一覧 | 05a | |
| 14 | 同・省略の注記 | なし | |
| 15 | 同・参加拒否の通知(5 種) | 05d | 本番経路 |
| 16 | `ClockPreflightNoticeView`(2 種) | 04c | 置き場所が違う(§6.4) |
| 17 | `EventCodeEntryView(.scanFlow)` | 13 / 13b | |
| 18 | `EventFoundView` | 05b(候補) | §4-h で確認 |
| 19 | `RecordingView` 入場演出 | 07 | |
| 20 | `RecordingView` 定常 | 要確認 | §4-b |
| 21 | 同・診断行 | なし | 一時的、出荷にも出る |
| 22 | 同・Simulate Signal Lost | なし | DEBUG のみ |
| 23 | `SignalLostView` | 05c | DESIGN ONLY、DEBUG のみ |
| 24 | `EventBindingSheetView` 署名依頼 | 要確認 | §4-c |
| 25 | 同・成功 `Sealed` | 06 | |
| 26 | 同・失敗 | 要確認 | §4-d |
| 27 | 同・Simulate binding | なし | DEBUG のみ |
| 28 | `AccountSheetView` | 10 | |
| 29 | ウォレット行(接続済み) | 10 / 10e | |
| 30 | ウォレット行(未接続) | 要確認 | §4-g、10b は NOT ADOPTED |
| 31 | `WalletConnectSheetView` | 要確認 | §4-f、Q1 |
| 32 | Bluetooth 行 | 10 / 10c | |
| 33 | 中継の脚注 | 要確認 | §4-e |
| 34 | `Venue broadcast` の行 | 14b | 経路が違う(§6.2) |
| 35 | `Disconnect Wallet` | 10 | 確認 10d は未実装 |
| 36 | `Join Event` の行 + シート | なし | Q なし(§2.1-6) |
| 37 | `Past Events` の行 | なし | Q2 |
| 38 | `Leave Event` の行 | なし | 撤去決定済み |
| 39 | `Version` 行 | 10 脚注 | |
| 40 | `ItemDetailView` | 08 / 09 | Q9 |
| 41 | `TransparencyView` | なし | Q3 |
| 42 | `ParticipationSummaryView` | なし | Q4 |
| 43 | `SessionParticipationListView` | なし | Q4 |
| 44 | `DailySummaryView` | なし | Q5 |
| 45 | `PastEventsView` | なし | Q2 |
| 46 | `VenueSignedServingView` | 14b | |
| 47 | `VenueLinkScannerView` | 14d | |
| 48 | カメラ拒否・制限・失敗 | 14f / 14f2 / 14f3 | |
| 49 | リンク拒否 3 種 | 14e / 14e2 / 14e3 | |
| 50 | pack 保存失敗 | 14g | |
| 51 | `VenueDeviceOrganizerView` | 14a | **到達不能**(§6.1)、Q8 |
| 52 | 鍵の復旧警告(3 種) | なし | Q7 |
| 53 | 鍵の利用不可警告 | なし | Q7 |

**集計:** フレームあり 27(うち候補 1)/ **なし 15** / 要確認 7 / **到達不能 3** /
枠 1 = **53**
