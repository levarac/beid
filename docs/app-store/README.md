# App Store 掲載・審査提出テキストの正本

App Store Connect に載せる文言は、**まずここに書いてからツールで反映する**。
App Store Connect の Web 画面で直接書き換えない。理由は 3 つある。

- 掲載文はアプリの挙動についての**対外的な主張**であり、実装が変わったら一緒に変えなければならない。
  リポジトリの中にあれば、挙動を変える PR のレビューで気づける。Web 画面にしか無い文言は誰も見に行かない。
- 審査ノートは審査員が読む手順書で、**書いてあるとおりに動かないと落ちる**。
  コードと同じ場所に置いて、同じ PR で直す。
- 反映は `apply-asc.sh` で、このディレクトリの JSON から読んで行う。手で打ち込むと、
  何をいつ変えたかが残らない。

## ファイル

| パス | 中身 | App Store Connect に反映するか |
| --- | --- | --- |
| `app-info/en-US.json` | サブタイトル | する |
| `version/1.0/en-US.json` | 説明文・キーワード・プロモーションテキスト・What's New | する |
| `ja-draft/version.json` | 上記の日本語版 | **まだしない**（下記） |
| `apply-asc.sh` | 上の JSON と年齢レーティングを App Store Connect に書き込むスクリプト | — |
| `review-notes.en-US.md` | 審査ノート本文と連絡先の草案 | する（`asc review details-create`） |
| `age-rating.md` | 年齢レーティング 24 問の回答と、その理由 | する（`asc age-rating edit`） |
| `privacy-labels.md` | プライバシーラベルの回答と、その根拠になるコード上の事実 | Apple の Web セッションが要る（後述） |
| `screenshots.md` | 必要なサイズと、撮るべき画面 | 画像は別途 |

## 日本語版を App Store Connect に反映していない理由

`docs/localization-process.md` にあるとおり、対象ロケールは owner decision (2026-08-21) で
`en` のみに決まっていて、そこには「ASC のノートとストア掲載も `en-US` のみに合わせる」と明記されている。
アプリ本体も `Localizable.xcstrings` が `en` 1 言語しか持っていない。

日本語版をここに置いてあるのは、**チーム内で内容を確認するため**と、
将来 `ja` を足す判断になったときに書き直さずに済むようにするため。
App Store Connect に `ja` ロケールを作るかどうかは、上記の決定を変える判断なので、
owner の決定を待つ。

## プライバシーラベルだけ手順が違う

App Store Connect の「App のプライバシー」(nutrition labels) は**公開 API から読み書きできない**。
`asc` にも `asc web privacy` という別系統のコマンドしか無く、これは Apple の Web セッション
（Apple ID + 2 要素認証）を必要とする。API キーでは通らない。

したがって手順は:

```sh
asc web auth login --apple-id "<owner の Apple ID>"   # 2FA。owner 本人しかできない
asc web privacy catalog --output json                 # 選択肢の正式なトークン名を取る
asc web privacy pull  --app 6789376188 --out ./privacy.json
# privacy-labels.md の回答どおりに privacy.json を編集
asc web privacy plan  --app 6789376188 --file ./privacy.json
asc web privacy apply --app 6789376188 --file ./privacy.json --confirm
asc web privacy publish --app 6789376188 --confirm
```

`privacy-labels.md` にトークン名そのものを書いていないのは、
カタログを引かずに書くと綴りを推測することになるため。**推測したトークンを置いて、
あとで誰かがそれを正しいものとして使うのが一番まずい。**

## 反映のしかた

`apply-asc.sh` を使う。テキストはすべてこのディレクトリの JSON から読むので、
**このリポジトリに無い文言が App Store Connect に書かれることは無い。**

```sh
docs/app-store/apply-asc.sh --dry-run   # 書き込む 6 件と文字数を表示するだけ
docs/app-store/apply-asc.sh             # 1 フィールドずつ書き込み、最後に validate を再実行
```

書き込むのは次の 6 件で、この順に実行する。

1. サブタイトル
2. 説明文
3. キーワード
4. プロモーションテキスト
5. What's New
6. 年齢レーティング（24 問を 1 回で）

入れていないものと理由:

- **著作権表示** — 名義（法人名か個人名か）は法的な宣言で、owner がまだ決めていない
- **審査情報** — 連絡先の氏名・メール・電話を推測で埋めない
- **サポート URL / プライバシーポリシー URL** — ページが実在しない
- **カテゴリ・第三者コンテンツ申告・配信地域・ビルド添付・提出** — このスクリプトの範囲外

JSON のフィールドが空のときは、書き込む前に止まる（空文字で上書きする事故を防ぐ）。

`asc metadata plan` / `approve` / `apply` の経路は使わない。`approve` が作業ディレクトリに
承認ファイルを書く手順を挟むため、1 回の承認で済まない。
