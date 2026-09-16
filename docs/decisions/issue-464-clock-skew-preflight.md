# Issue #464 — 端末時計の preflight: 信頼時刻・許容 skew・offset 有効期間

**Status:** 提案（maintainer 未承認）。数値はすべて `eninSeconds`（B004 の deployment parameter、`12..3600` に clamp）の関数として決める。窓境界の意味論（barnard#180 / #200）と Observation の ENIN 検査（parallax#54）は再定義しない。

## 1. 信頼できる時刻と取得方法

- **時刻源（提案）**: operator origin（`https://parallax-observation-operator.levarac.workers.dev`。両 app の event code lookup URL template の既定 origin）に HTTPS `HEAD` を 1 回送り、応答の `Date` header（IMF-fixdate、秒精度）を読む。status は問わない。TLS で operator を認証でき、join flow が既に依存している相手なので新しい信頼先を増やさない。
- **測り方**: 送信直前に端末の壁時計 `w0` と monotonic `m0`、受信直後に monotonic `m1` を読む。server が `Date = D` を返した真の瞬間は `[D, D+1s)` のどこかで、そのときの端末壁時計は `w0 + [0, m1-m0]` のどこか。したがって offset（端末 − 信頼時刻）は区間 `[w0 - D - 1000ms, w0 + (m1-m0) - D]` に入る。受信後の壁時計を使わないので、通信中に壁時計が変えられても区間は壊れない。
- **不採用**: Sepolia の block timestamp。registry が pin する `safe`/`finalized` は数分遅れ、`latest` でも slot 12 秒で、しかも遅れの上限を端末側で保証できない（下界しか取れない）。
- **役割分担**: HTTP 通信と時計の読み取りは native。区間計算・判定・cache は `shared/`（`org.levarac.beid.shared.clock`）。

## 2. 許容 skew

- **許容値 `T = eninSeconds / 10`**（既定 300 秒なら 30 秒）。
- **根拠**: `currentEnin = floor(t / eninSeconds)` なので、ずれ δ（< eninSeconds）の端末は各 ENIN 境界の前後 δ 秒だけ隣の ENIN を名乗る。spec 134 の `[validFromEnin, relayExpiresAtEnin)` 判定も、phase-1 lease の `currentEnin + 1` 上限も ENIN 単位なので、誤判定しうる時間は各 ENIN の `δ / eninSeconds` の割合になる。`T` はこの割合を 10% 以下に抑え、判定が 1 ENIN を超えて動かないことを保証する。
- **判定（3 状態）**: offset 区間 `[lo, hi]` について
  - `lo >= -T かつ hi <= T` → **許容内**
  - `lo > T または hi < -T` → **許容超過**
  - それ以外（区間が ±T をまたぐ、測定なし、cache 失効、`eninSeconds` が範囲外）→ **確定不能**
- 測定の不確かさ（RTT + 1 秒）が `T` より大きい場合は許容内にも超過にもならず確定不能になる。`eninSeconds = 12`（`T = 1.2s`）ではほぼ常に確定不能になるが、秒精度の時刻源では ENIN を確定できないという事実どおりの結果で、下限値で上書きしない。

## 3. cache した offset の有効期間

- **有効期間 `V = 12 × eninSeconds`**（既定なら 1 時間）。spec 134 の relay 寿命上限 12 ENIN と同じで、1 回の測定が gate の対象より長く効かないようにする。
- 経過時間は monotonic（sleep 中も進むもの: Android `SystemClock.elapsedRealtime()`、iOS `CLOCK_MONOTONIC_RAW`）で測る。monotonic が巻き戻ったら（再起動）失効。
- **cache 使用時の補正**: 測定後の `Δwall − Δmono` を offset 区間に足し、さらに水晶の誤差として `±Δmono × 100ppm`（切り上げ）だけ広げてから判定する。利用者が手動で時計を進めた場合、再測定なしで即座に許容超過になる。`V` 経過時の 100ppm は `0.0012 × eninSeconds`（300 秒で 0.36 秒）で、`T` に比べて十分小さい。
- 失効後は再測定する。再測定が失敗したら確定不能（古い cache を延命しない）。

## 4. `eninSeconds` の出どころ

beid は Barnard engine の ENIN 設定を変えておらず、両 SDK とも engine の `eninSeconds` を公開していない。そのため判定 API は `eninSeconds` を必ず引数に取り、native は「beid が Barnard engine を動かしている値」を一箇所に名前付きで持って渡す（現状は SDK 既定の 300）。検証済み envelope の `eninSeconds` が手元にある経路では、その値で判定する。

## 5. UX

- **許容超過**: 「この端末の時計がずれています」+ 自動設定を促す文 + 再確認ボタン。
- **確定不能**: 「時刻を確認できませんでした」+ 通信状況を確認して再試行を促す文 + 再確認ボタン。
- 表示場所は既存の join flow（Android: Join event 画面の状態表示、iOS: home の event 開始導線）。両状態とも黙って進めない。

## 6. この PR でやらないこと

- relay / venue serving を preflight の結果で止める配線（iOS `VenueDeviceClock` の `.unavailable` 化を含む）。表示と判定を先に置き、fail-closed の配線は別 PR で決める。
- 4 つの窓境界の実機試験（dispatch#62）。
