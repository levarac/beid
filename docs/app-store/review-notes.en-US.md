# App Review notes (en-US)

これは `asc review details-create --notes` に入れる本文の正本。
**書いてあるとおりに動かないと落ちるので、ビルドの挙動が変わったらこのファイルも同じ PR で変える。**

## 現行ビルドで書ける版（NOW）

下の本文は、**提出する Release ビルドで審査員が実際にできることだけ**を書いている。
デモ経路（`useDemoEventMode`）は Release ビルドで常に無効なので、
「コードを入れるとデモが動きます」とは書けない。書けば嘘になり、審査員はその場で詰まる。

> ### What beid does
>
> beid records that a person was physically present at an event. It does this without identities:
> two phones running beid near each other exchange rotating identifiers over Bluetooth Low Energy
> and each signs an observation that the other was nearby. When enough mutual observations
> accumulate, the app writes an attendance record into the user's local collection.
>
> ### Why this app needs a second device
>
> **The core feature cannot be exercised by one device alone.** That is not a limitation we can
> work around — it is the product. A record only exists because a *different* phone observed this
> one. A single phone with no peer nearby will correctly show the "sensing" state and produce no
> record, which is the honest result rather than a failure.
>
> <VIDEO — 添付してからこの段落を使う。動画がまだ無いなら、この段落ごと削る。>
> We have attached a video showing the complete flow between two devices at a real event:
> joining, mutual sensing, the record appearing, and the record's detail.
>
> ### What you can verify on one device
>
> 1. Launch the app. No account, no sign-up, and no wallet is required to proceed.
> 2. Onboarding asks for Bluetooth permission. Grant it.
> 3. On the home screen, tap "Sense Event". The app starts scanning. With no other beid device
>    nearby it stays on the sensing screen — this is the expected result described above.
> 4. Alternatively, enter the event code below to join a registered event directly. The app
>    verifies the event against a public registry before joining, so this also demonstrates the
>    network and verification path. It will still not produce a record without a nearby peer.
>
> Event code: **<CODE>** (valid through <DATE>; contact us if it has lapsed and we will reissue)
>
> ### Bluetooth background modes
>
> The app declares `bluetooth-central` and `bluetooth-peripheral` background modes. Both are
> essential: the app must keep observing and keep being observable for the duration of an event,
> which routinely runs for hours while the phone is in a pocket. If the app stopped when
> backgrounded, it would record nothing, which is its only function.
>
> ### Wallet (MetaMask)
>
> Connecting a crypto wallet is **optional** and is used for exactly one thing: signing an
> attendance record so it is bound to a key the user controls. The app sells nothing, holds no
> funds, initiates no transfers, and contains no in-app purchases or cryptocurrency exchange.
> Users who do not have a wallet use the event-code path above and are never blocked.
>
> ### Data
>
> While a user takes part in an event, the app uploads signed proximity observations to the
> event's report server, named by the event's published definition. An observation carries a
> per-event pseudonymous key, the rotating Bluetooth identifiers the device heard, the event
> identifier and the time window. It carries no name, account, email, phone number, device
> identifier, wallet address or location coordinates, and it is not used for tracking or
> advertising. The server keeps accepted observations so anyone can verify the event's
> attendance record later. Other outbound requests read public event definitions and verify an
> event code.
>
> ### Contact
>
> <CONTACT NAME>, <CONTACT EMAIL>, <CONTACT PHONE>. We can arrange a live two-device demonstration
> over video call at your convenience.

## dispatch#61 が実装された後の版（LATER — まだ使わない）

dispatch#61 で「Release ビルドにレビュー済みの審査用ウォークスルーを入れる」が完了したら、
上の「What you can verify on one device」を次で差し替える。**#61 がマージされるまでこのブロックは使わない。**

> ### What you can verify on one device
>
> 1. Launch the app and grant Bluetooth permission.
> 2. <#61 が定めた入口の操作をここに書く>
> 3. The app runs a scripted walkthrough of the full flow — joining, sensing, a record being
>    produced, and the record's detail — with no second device and no venue equipment.
> 4. Records produced this way are marked as demonstration records and are visibly distinguished
>    from records produced by real sensing.

## 埋めるべき穴

| 穴 | 誰が | 状態 |
| --- | --- | --- |
| `<CODE>` — 審査員に渡すイベントコード | ops-event | **今あるイベントは使えない**（下記）。載せるなら審査専用イベントを登録する |
| `<DATE>` — そのコードの有効期限 | ops-event | 審査専用イベントの定義の窓の終わり。審査期間より十分先にする |
| `<CONTACT NAME/EMAIL/PHONE>` | Ken | 審査情報の必須項目。推測で埋めない |
| 2 台間のデモ動画 | Ken / devices seat | `asc review attachments-upload` で添付できる |

## 注意

- **イベントコードの有効期限が審査中に切れるのが、この経路の一番ありそうな失敗**。
  `DefinitionSelection.kt` は `validFrom <= now <= validUntil` で切るだけなので、
  窓を出た瞬間にコードが通らなくなる。審査は数日〜数週間開くことがある。
- 審査ノートに「デモモードがあります」と書かない。Release ビルドには無い。
- **既存のイベントはどれもコードに使えない**（ops-event, 2026-09-17 19:2x JST に確認）。
  `parallax-demo` は無効化済み（`acceptanceEnabled false`）。受付中の `parallax-sepolia-20260917-05` は
  定義の窓が 2026-09-19T00:25Z で終わる。定義の窓には上限が無いので、審査専用に長い窓のイベントを登録すれば
  コード入力から参加までは審査期間中も通る。
- **会場のリンクや QR は審査ノートに載せない。** 会場が配る envelope には端末側で強制される 60 分のリースがあり、
  再署名のたびにリンクが無効になる。数日開く審査の間に必ず切れる。
- 手順 4 は「参加できる」ことしか示さない。観測相手がいないので記録は生まれない。ノートの文面もそう書いてある。
