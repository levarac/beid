# 年齢レーティングの回答

`asc age-rating edit --app 6789376188 --<flag> <value>` で設定する。
App Store Connect 上は 24 問すべてが `null` で、全部がブロッキングエラーになっている。

**回答の原則: 実際にアプリに無いものは `false` / `NONE`。「たぶん無い」で埋めない。**
迷った 2 問については理由を下に書いた。

| 設問 | 回答 | 理由 |
| --- | --- | --- |
| `advertising` | false | 広告 SDK も広告枠も無い |
| `alcoholTobaccoOrDrugUseOrReferences` | NONE | 該当なし |
| `contests` | NONE | 該当なし |
| `gambling` | false | 該当なし |
| `gamblingSimulated` | NONE | 該当なし |
| `gunsOrOtherWeapons` | NONE | 該当なし |
| `healthOrWellnessTopics` | false | 健康・ウェルネスの話題を扱わない |
| `lootBox` | false | 該当なし |
| `medicalOrTreatmentInformation` | NONE | 該当なし（真偽値ではなく頻度で答える設問） |
| `messagingAndChat` | false | **下記参照** |
| `parentalControls` | false | 保護者向け機能は無い |
| `profanityOrCrudeHumor` | NONE | 該当なし |
| `ageAssurance` | false | 年齢確認の仕組みを持たない |
| `sexualContentGraphicAndNudity` | NONE | 該当なし |
| `sexualContentOrNudity` | NONE | 該当なし |
| `socialMedia` | false | **下記参照** |
| `socialMediaAgeRestricted` | false | `socialMedia` が false のため |
| `horrorOrFearThemes` | NONE | 該当なし |
| `matureOrSuggestiveThemes` | NONE | 該当なし |
| `unrestrictedWebAccess` | false | アプリ内ブラウザも任意 URL を開く導線も無い |
| `userGeneratedContent` | false | **下記参照** |
| `violenceCartoonOrFantasy` | NONE | 該当なし |
| `violenceRealistic` | NONE | 該当なし |
| `violenceRealisticProlongedGraphicOrSadistic` | NONE | 該当なし |
| `kidsAgeBand` | 設定しない | Kids カテゴリに出さない |

## 迷った設問

### `messagingAndChat` = false

端末同士は Bluetooth で通信するが、**人が人にメッセージを送る手段が無い**。
交換されるのは回転する識別子と署名付きの観測記録だけで、自由入力のテキストは一切乗らない。
「通信している」と「メッセージ機能がある」は別物なので false。

### `socialMedia` = false / `userGeneratedContent` = false

境界線が 1 か所ある。会場端末（venue device）のセットアップで、
**運用者が端末に表示名（ラベル）を入力でき、それが周囲にブロードキャストされる**。
アプリ内の文字列自身が「beid はこのブロードキャストを検証しない。近くにいる人は誰でもここで設定した名前を見られる」
と警告している。

これを「ユーザー生成コンテンツ」と呼ぶかどうかは判断が要る。**false にした根拠は 3 つ。**

1. 入力できるのは**イベント主催者・会場運用者だけ**で、一般の参加者には入力欄が無い。
2. 入力できるのは 1 つの短いラベルだけで、投稿・コメント・プロフィール・他人への公開といった
   UGC の仕組みが無い。
3. 参加者同士が見るものの中に、人が書いた文字列は入らない。

**ただしこれは「安全側に倒した」判断ではなく「該当しない」という判断なので、
Ken が別の読みをするなら `userGeneratedContent = true` に倒す余地がある**
（true にすると、通報・ブロック・モデレーションの仕組みを審査で求められる可能性がある）。
false で出して指摘されたら、そのとき会場ラベルの説明を添えて再提出するのが現実的。

## 見込みレーティング

上記の回答だと **4+** になる見込み。`ageRatingOverride` は `NONE` のまま。

## 適用コマンド

`docs/app-store/apply-asc.sh` の 6 番目の手順が、この表の 24 問をそのままフラグで渡す。
`--all-none` を使わず 1 問ずつ書いてあるのは、どの値がこの表のどの行から来たかを追えるようにするため。
表を変えたらスクリプトも同じ PR で変える。
