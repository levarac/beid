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
> This build does not upload observations to any server. Report submission exists in the codebase
> but is switched off in shipping builds by a build setting (`BeidReportSubmissionEnabled = NO`),
> and records stay on the device. The app's outbound network requests are limited to reading
> public event definitions and verifying an event code.
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
| `<CODE>` — 審査員に渡すイベントコード | ops-event | 有効期限を照会中。**審査期間中ずっと有効である必要がある** |
| `<DATE>` — そのコードの有効期限 | ops-event | 同上 |
| `<CONTACT NAME/EMAIL/PHONE>` | Ken | 審査情報の必須項目。推測で埋めない |
| 2 台間のデモ動画 | Ken / devices seat | `asc review attachments-upload` で添付できる |

## 注意

- **イベントコードの有効期限が審査中に切れるのが、この経路の一番ありそうな失敗**。
  `DefinitionSelection.kt` は `validFrom <= now <= validUntil` で切るだけなので、
  窓を出た瞬間にコードが通らなくなる。審査は数日〜数週間開くことがある。
- 審査ノートに「デモモードがあります」と書かない。Release ビルドには無い。
