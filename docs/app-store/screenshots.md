# スクリーンショット

現状 App Store Connect に**セットが 0 件**で、ブロッキングエラーになっている。
画像はここでは作らない（実機の絵が要る。捏造しない）。必要なサイズと、撮るべき画面を決めておく。

## 必要なサイズ

`asc screenshots sizes` の出力そのまま。

| displayType | 受け付ける解像度（縦） |
| --- | --- |
| `APP_IPHONE_65` | 1242 × 2688 または 1284 × 2778 |
| `APP_IPAD_PRO_3GEN_129` | 2048 × 2732 または 2064 × 2752 |

**iPad が要るのは `ios/project.yml` の `TARGETED_DEVICE_FAMILY: "1,2"` が iPhone + iPad だから。**
iPad を対象から外す（`"1"` にする）なら iPad のスクリーンショットも iPad での確認も丸ごと不要になる。
これは `project.yml` を触るコード変更なので、撮影を始める前に決めたほうが安い。

セットあたり 1〜10 枚。**3 枚は入れたい。**

## 撮るべき画面

順番に意味を持たせる。1 枚目だけ見て何のアプリか分かるようにする。

| # | 画面 | 何を見せるか | どう用意するか |
| --- | --- | --- | --- |
| 1 | Recording / 記録中 | 周りの端末を観測している最中の画面。**このアプリの中身はこれ** | 2 台以上必要。会場でなくても、beid を動かした端末が 2 台隣にあれば出る |
| 2 | コレクション（記録一覧） | 記録が貯まった状態 | 記録が 1 件以上ある端末 |
| 3 | 記録の詳細 | 署名付きの観測が根拠になっていること | 同上 |
| 4（任意） | Welcome / オンボーディング | 登録不要・匿名であること | 1 台で撮れる |
| 5（任意） | イベントコード入力 | ウォレット不要で参加できること | 1 台で撮れる |

**1〜3 は 1 台では撮れない。**記録は他の端末に観測されて初めて生まれるため。
dispatch#60 の小規模実機試験と同じ機材で、同じ日にまとめて撮るのが一番安い。

Simulator で撮ったものは使えない。Simulator には BLE が無く、Debug ビルドの DemoEvent モードで
作った画面は**架空の観測データ**なので、ストアに載せると実際の挙動と違う絵になる。

## アップロード

```sh
asc --profile KENICHINAOE screenshots upload \
  --version-localization e7f2e26a-95ea-41a1-8246-375b9b43f09d \
  --path ./screenshots/iphone --device-type IPHONE_65

asc --profile KENICHINAOE screenshots upload \
  --version-localization e7f2e26a-95ea-41a1-8246-375b9b43f09d \
  --path ./screenshots/ipad --device-type IPAD_PRO_3GEN_129
```

撮った画像自体はこのリポジトリに入れない（サイズが大きく、差分の意味も無い）。
