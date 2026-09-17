# App Store 掲載・審査提出テキストの正本

App Store Connect に載せる文言は、**まずここに書いてからツールで反映する**。
App Store Connect の Web 画面で直接書き換えない。理由は 3 つある。

- 掲載文はアプリの挙動についての**対外的な主張**であり、実装が変わったら一緒に変えなければならない。
  リポジトリの中にあれば、挙動を変える PR のレビューで気づける。Web 画面にしか無い文言は誰も見に行かない。
- 審査ノートは審査員が読む手順書で、**書いてあるとおりに動かないと落ちる**。
  コードと同じ場所に置いて、同じ PR で直す。
- 反映は `asc metadata plan` → `apply` で差分を取って行う。手で打ち込むと、
  何をいつ変えたかが残らない。

## ファイル

| パス | 中身 | App Store Connect に反映するか |
| --- | --- | --- |
| `en-US/app-info.json` | アプリ名・サブタイトル・プライバシーポリシー URL | する |
| `en-US/version.json` | 説明文・キーワード・サポート URL・プロモーションテキスト | する |
| `ja/app-info.json`, `ja/version.json` | 上記の日本語版 | **まだしない**（下記） |
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

```sh
# 差分を見る
asc --profile KENICHINAOE metadata plan \
  --app 6789376188 --version 1.0 --platform IOS --dir docs/app-store

# 適用する
asc --profile KENICHINAOE metadata apply \
  --app 6789376188 --version 1.0 --platform IOS --dir docs/app-store --confirm

# 提出前チェックを再実行して blocking が減ったことを確認する
asc --profile KENICHINAOE validate \
  --app 6789376188 --version-id <VERSION_ID> --platform IOS --output table
```

`asc metadata` が読むのは `app-info/<locale>.json` と `version/<version>/<locale>.json` という
レイアウトなので、反映時は `en-US/` の中身をその形に移す（`plan` が読めない配置なら差分ゼロで
黙って通ってしまうため、必ず `plan` の出力に変更行が出ることを確認する）。
