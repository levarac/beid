# Issue #653 — drawing each record's Sigil from its own data: design

**Status:** design approved by the PM on 2026-09-27 (§8 lists the picks);
phase 2 is implemented in the working tree of `work/issue-653-sigil-data`,
not yet committed. Appendix B records what the implementation changed or
settled.
**Checked against:** `62531fe` (branch `work/issue-653-sigil-data`). File:line
citations of existing code refer to that commit, before phase 2; phase 2 code
is cited by symbol, because its line numbers move with every edit. Barnard
citations are against the pinned 0.9.2 checkout, revision `61e2f0b`
(`Package.resolved`), paths relative to `packages/swift/barnard/Sources/`.
**Governing rule:** DECISIONS 2026-09-27 [規範] (`DECISIONS.md:2128`), lines
(a)–(d). The owner authorized storing per-window, per-peer presence **on the
device only**.

**In one paragraph.** At session end, shared code turns the observations the
session already holds (the same ones the counts come from) into a small
per-record presence table. Each peer appears under a **random 16-byte token
drawn for that record**, so a stored token is unrelated to the peer's display
id and to that peer's token in any other record. v1 stores presence 1 only and
has no way to write presence 2. The table goes into a new iOS-only store, keyed
by `proofId` and excluded from device backup. The existing
`SessionAggregateSnapshot` format stays unchanged. The design stores no salt and
no key. A record without a row keeps today's neutral ring.

---

## 1. What is stored

### 1.1 The token (question A)

| Candidate | Stable across windows? | Why it is or is not used |
| --- | --- | --- |
| RPID (`peerKey` in aggregation) | **No.** It rotates every ENIN window (`SensingCoordinator.swift:285-288`) | Forbidden by the brief. It would also give every window its own angle. |
| Display id (`detectedDisplayId`) | **Yes.** Barnard derives it as `SHA256(TEK)[0:4]` (`BarnardCore/BarnardCoreCrypto.swift:252-254`), with `TEK = HKDF(deviceSecret ‖ eventCode)` (`:166-175`). `deviceSecret` is persisted by Barnard's key storage (`Barnard/BarnardRpidGenerator.swift:150-158`). | This is the only identifier that is stable across windows, and it drives the in-memory map (below). **It is never stored.** It is stable per (peer device, event code) across sessions, days and restarts, and it is served in the clear over GATT B003 (`Barnard/BarnardEngine.swift:2192-2193`). Storing it, or any deterministic function of it, would link every record of the same event to each other and to the physical device that serves that value. |
| HMAC(display id) with a salt | yes | Rejected as the default, see OD-1. The preimage is 4 bytes (`ObservationAggregation.kt:94-98`), so anyone who holds both the salt and a stored value can enumerate 2^32 candidates. The salt would therefore have to live apart from the data, in the Keychain, and iOS Keychain items outlive an uninstall. |
| **Random per-record token (proposed)** | yes, within the record | It carries no information about the display id, so there is nothing to brute-force and nothing to keep secret. |

**Where the stable id lives today.** `SensingCoordinator` receives the display
id with each detection (`handleDetection`, `SensingCoordinator.swift:1714-1720`).
It normalizes the id through shared code (`:2125`), keeps it in the in-memory
`detectedDisplayIDs` set (`:317-321`, `:2127-2129`), and passes it into
`AggregationRuntime.recordObservation` (`:2146`). That call forwards it into
shared's `AggregationObservationInput` (`AggregationRuntime.swift:41-49`), whose
list is `internal` (`ObservationAggregation.kt:20-25`). All of this is cleared
in `resetSessionState()` (`SensingCoordinator.swift:2859-2864`).

**Stability, precisely.**
- Across windows within one record: yes. `displayId4` takes no ENIN.
- Across app restarts mid-event: the peer's value is unchanged, but **a record
  never spans a restart**. A new session resets the aggregation
  (`SensingCoordinator.swift:3746-3747` → `:2861`) and creates a new Proof
  (`:3758-3761`). The count snapshot is written only on a graceful
  `endSensing` (`:2839-2841`, `:4536-4543`), so a killed session persists
  neither counts nor presence (see §4).

**Mechanism.**
1. A shared session object holds `normalized display id → token` in memory
   only.
2. Tokens are 16 bytes from the native CSPRNG, encoded as 32 lowercase hex
   characters. Randomness comes in through a port, as the foundation manual
   requires (`docs/kmp-shared-foundation.md:217`).
3. The session object is dropped in `resetSessionState()`.

The stored token is the random value itself, never a function of the id. The
design needs no salt and no key, so binding limit 2 holds with nothing to put
in the Keychain.

`BeidSystemRandomSource` ignores the `SecRandomCopyBytes` status
(`OwnerKeyProvider.swift:221-226`). If it fails, every token becomes zero. The
shared builder therefore rejects a duplicate token and fails the whole record,
which then shows the neutral ring. It never merges peers.

**What `SigilLayout` needs.** It needs an opaque key and nothing else. The key
must be non-empty, valid UTF-8 and at most 4 KiB (`ObservationAggregation.kt:327-336`).
The angle is `FNV-1a(key) mod 360` (`SigilLayout.kt:545-554`).
`addSigilPresence` also takes a window index in `[0, W)` and a presence value
of 1 or 2 (`SigilLayout.kt:319-353`). `createSigilInput` takes `W` (`:286`).

**Which peers are drawn.** Only observations that carry a display id.
Observations without one (B003 failed) are excluded: their only identifier is
the per-window RPID, so they cannot be followed across windows. The drawn peer
set is therefore exactly the set behind the snapshot's `deviceCount`
(`ObservationAggregation.kt:303`, `:318-322`), including its documented 4-byte
collision undercount (`:94-98`).

### 1.2 Presence, window axis, and presence 2

- **Presence 1:** a (token, window) pair is present when at least one accepted
  observation with that display id fell in that ENIN window. The builder reads
  the **same** `AggregationObservationInput` the counts are computed from, so
  the detection path gets no new hook. An observation that aggregation rejects
  at its 100,000 cap (`ObservationAggregation.kt:3`, `:187`) is missing from
  both the counts and the Sigil.
- **Window axis:** `W` is the number of distinct ENINs among the session's
  observations. That equals the snapshot's `windowCount`, which frames 04, 08
  and 09 already show. A window is stored as its rank in ascending ENIN order.
  See OD-2 for the alternative (the full span, including empty windows).
- **Presence 2 is never written by v1.** The builder API has no `mutual` input,
  and the v1 format has no presence column, so every stored entry is presence 1
  by definition.

  The evidence that could justify presence 2 is #144 Stage 4: a verifier
  matching A's signed record that names B's window RPID with B's record that
  names A's (`docs/decisions/issue-144-attestation-contract.md:97-105`,
  `:155`). No such matcher exists (`:107`, `:141`). If a verifier statement
  ever came back to the device, it would identify the reciprocated peer by
  window RPID. v1 keeps no RPID-to-token mapping, and RPIDs leave the local
  store after submission (`ReportSubmissionRuntime.swift:262-265`). **A v1
  record can therefore never gain presence 2 later**, which also satisfies
  line (d): no backfill.

### 1.3 Stored layout (shared codec, v1)

```
beid-sigil-presence\t1
windows\t<W>
peers\t<P>
peer\t<token>\t<rank>,<rank>,...     ← P lines, sorted by token; ranks ascending, unique, < W
end
```

| Field | Type | Notes |
| --- | --- | --- |
| `W` | Int, 1…100,000 | Equals the snapshot `windowCount` |
| `token` | 32 lowercase hex | Random per record. Lines are sorted by token, so the file order says nothing about display ids or first-seen order. |
| `rank` | Int, 0…W−1 | No ENIN and no timestamp is stored in this file |

There is no display id, no RPID, no ENIN, no count and no signal strength.
Decoding is strict and canonical: text that does not re-encode to identical
bytes is rejected, as in `SessionAggregateSnapshot.kt:104-126`. The native
record is `{proofId, presenceText, createdAt}`, mirroring
`SessionAggregateSnapshotRecord.swift:16-31`, with one immutable row per
`proofId` (`SessionAggregateSnapshotStore.swift:19-21`).

### 1.4 Caps and sizes

| Limit | Value | Beyond it |
| --- | --- | --- |
| Peers per record | 1,024 (`MAX_SIGIL_PEER_COUNT`, `SigilLayout.kt:148`) | The builder fails with `too_many_peers`. **No row is written**, so the record shows the neutral ring. No partial drawing (OD-4). |
| (peer, window) entries | ≤ observations ≤ 100,000, which is `MAX_SIGIL_ENTRY_COUNT` (`SigilLayout.kt:151`) | Cannot be exceeded |
| `W` | ≤ 100,000 ≤ `MAX_SIGIL_WINDOW_COUNT` (`:140`) | Cannot be exceeded |
| Bytes per record | Typical (40 peers, 12 windows, about 8 each): **≈2.2 KB**. Worst case: 1,024 × 39 B + 100,000 × 6 B ≈ **0.64 MB** | Encoder cap of 8 MiB, the same value as `SessionAggregateSnapshot.kt:4` |
| In-memory map | ≤ 1,024 entries | Released at session end |

### 1.5 Retention and deletion

| Event | Behavior | Evidence |
| --- | --- | --- |
| Record exists | The row is kept for the record's lifetime | — |
| Delete one record | **No such path exists on iOS today.** `ProofStore` has `add`/`proof`/`update*` only (`ProofStore.swift:40-67`). Phase 2 adds `remove(proofId:)` to the new store. The future record-delete path must call it (proposed issue, §5). | — |
| "Delete all data" / app reset | **No such feature exists.** The only destructive UI action is Disconnect wallet (`AccountSheetView.swift:109`, `:345`). The only reset is `ProofStore.resetForUITesting()` (`ProofStore.swift:131-136`), called under `-beid-ui-test` (`AppCoordinator.swift:190`). Phase 2 clears the new store at the same place. | — |
| Uninstall | The app container is removed. The design stores nothing in the Keychain, so nothing outlives the app. | — |
| Device backup / migration | The file is **excluded from backup** (§3). On a restored or migrated phone the records come back without presence rows and show the neutral ring. | — |
| Session killed before `endSensing` | Nothing is written, the same as the count snapshot | `SensingCoordinator.swift:4536-4543` |

---

## 2. Where (question C)

| | Option 1: extend `SessionAggregateSnapshot` (v2) | **Option 2: separate store keyed by `proofId` (recommended)** |
| --- | --- | --- |
| Shared change | Bump the header `…\t1` (`SessionAggregateSnapshot.kt:3`). The strict decoder must then accept both v1 and v2. | New codec and builder in `org.levarac.beid.shared.sigil`. The snapshot codec is untouched. |
| Android | **Changes behavior.** Android persists the same snapshot (`android/.../persistence/SessionAggregateSnapshot.kt:19-59`, `EventJoinCoordinator.kt:1040-1047`), and `allowBackup="true"` (`AndroidManifest.xml:16`) would ship presence to Auto Backup. Android has no screen to use it on. | No Android production change (§5) |
| Separating the privacy-sensitive part | Presence would ride along with the counts. The counts are decoded by every summary reader (for example `SensingCoordinator.swift:544-546`). | Only the Sigil path reads it |
| Revocation or deletion | Snapshots are immutable (`SessionAggregateSnapshotStore.swift:19-21`), so dropping presence means rewriting evidence-adjacent rows | Delete one row or one file |
| Backup exclusion | Would also exclude the counts, or need a second file anyway | One file, one flag |
| Cost | One write | A second best-effort write next to `SensingCoordinator.swift:2841` |

**Recommendation: Option 2.**

**Presence reducer: in `shared/` under either option.** It decides which
observations count, the window ranks, the cap behavior and the byte format.
Both OSes must give the same answer to all of these (AGENTS.md ownership
table). The native side keeps only CSPRNG bytes, the file location, the atomic
write, the backup flag, and the call site.

KMP ledger row (`docs/kmp-shared-foundation.md:28-45`):
`sigil presence | C / INVENT | current_ios: none | current_android: none |
invariants §1, §3 | owner #653 | shared_symbol: BeidSharedKit.sigil.* |
licensing_test: SigilPresenceTest | platform_callers: iOS SensingCoordinator,
RecordSigilSlot callers`.

The exported API, as built (`shared/.../sigil/SigilPresence.kt`). Package
placement is API: the package sits inside the module root, so the Swift
spelling is `BeidSharedKit.sigil.<Name>`. Every name and type below was read
back from the generated `BeidSharedKit.swift` (DECISIONS 1908); Kotlin `Int`
is `Swift.Int32` there.
- `SigilPresenceSession`, `createSigilPresenceSession()`
- `sigilPresenceTokensNeeded(session:observations:) -> Int32`: how many
  display ids seen so far still need a token. It returns 0 once the session can
  no longer produce a record.
- `addSigilPresenceToken(session:observations:token:) -> Bool`: assigns the
  token to the earliest-seen display id without one. A token that is not 32
  lowercase hex characters is refused and assigns nothing. A duplicate token
  fails the session for good.
- `buildSigilPresenceInput(session:observations:) -> SigilPresenceInputResult`:
  the live input (`isSuccess`, `errorCode`, `input`)
- `encodeSigilPresenceSnapshot(session:observations:)` (`snapshotText`) and
  `decodeSigilPresenceSnapshot(encoded:)`, which returns the `SigilInput`
  directly (`isSuccess`, `errorCode`, `input`)

Error codes: `input_mismatch`, `duplicate_token`, `too_many_peers`,
`missing_token`, `no_windows`, `too_many_windows`, `snapshot_too_large`,
`invalid_snapshot`, `noncanonical_snapshot`.

**iOS wiring in phase 2.**
1. `AggregationRuntime` exposes its input read-only.
2. After `recordDeviceIdentity` (`SensingCoordinator.swift:2146`), top up
   tokens. This costs one CSPRNG call per new peer only.
3. At `endSensing`, write the presence row beside `:2841`, before
   `resetSessionState()` (`:2853`).
4. Drop the session object in `resetSessionState()` (`:2859-2861`).

The store is `SigilPresenceStore`, at
`Application Support/SigilPresence/sigil-presence.json`. Both the directory and
the file are excluded from backup, because an atomic write replaces the file
and drops a mark set on the old one. It has the same quarantine and suspension
shape as `SessionAggregateSnapshotStore.swift:130-144`.

---

## 3. What never leaves the device (question D)

Presence data exists in exactly two places: the in-memory session object next
to `aggregationRuntime` (`SensingCoordinator.swift:987`), and the new store.
Every outbound path below is built from inputs listed at its own call site, and
none of those inputs is either of the two.

| Outbound path | Inputs (cited) | Presence can reach it? |
| --- | --- | --- |
| Report submission (capture → Observation → POST) | `closeWindow` passes `id, eventCode, eventIdHex, enin, peerRpids, reporterRpid, commit` (`SensingCoordinator.swift:4285-4295`), stored as `ReportSubmissionCapture` (`ReportSubmissionStore.swift:54-63`) and POSTed by `client.submit` (`ReportSubmissionRuntime.swift:479-484`) | No |
| Legacy window report and its signature | `windowReportPayload(eventCode, enin, peerRpids, commit)` signed at `SensingCoordinator.swift:4304-4310` (`:4392`). `WindowReport` fields are at `WindowReport.swift:12-23`. | No |
| Unsent-window ledger | `closeWindow(windowId, persistedObservationReference)` (`SensingCoordinator.swift:4348-4351`) | No |
| Self-proof signature | `SelfProofRecord` fields: event, ENIN range, keys, signature (`SelfProofRecord.swift:19-34`) | No |
| Count snapshot | Counts only (`SessionAggregateSnapshot.kt:46-79`); unchanged under Option 2 | No |
| Public data | None exists (`issue-145-privacy-schema.md:11-12`, `:37-40`) | No path exists |
| Share / export / pasteboard | `ios/Beid` has 0 hits for `ShareLink`, `UIActivityViewController` and `fileExporter`. Pasteboard writes are the wallet address (`AccountSheetView.swift:264`, `:284`), the event id (`VenueSignedServingView.swift:310`) and the WalletConnect URI (`WalletConnectView.swift:251`). | No |
| Other network | Clock preflight `HEAD` (`ClockPreflightController.swift:40-43`); venue artifact fetch (`VenueArtifactAcquisition.swift:92-100`) | No |
| BLE | Barnard advertises its own TEK-derived payload (`Barnard/BarnardRpidGenerator.swift:115-145`) | No |
| Logs | `Logger`s at `SensingCoordinator.swift:631` and `:641`. The new store logs only a **payload-free** error enum, never a token or display id. | No, by construction |
| Analytics | 0 hits in `ios/Beid` for analytics / telemetry / crashlytics / firebase / sentry | No path exists |
| **Device backup** | **Today no store is excluded** (0 hits for `isExcludedFromBackup`). Every store lives in Documents (for example `SessionAggregateSnapshotStore.swift:59-62`). | **Yes, unless excluded.** The new file must set `isExcludedFromBackup`. |
| View layer | `SigilLayout.peerAt(...).peerKey` is public (`SigilLayout.kt:234-238`, `:278`). `SigilView` reads only primitives and counts (`SigilView.swift:122-167`, `:180-189`). | Stays on screen. A source walk forbids `peerAt(` anywhere in production. |

**Residual risk.** Tokens remove identity, not structure. Someone holding the
raw files of two devices from the same event could try to pair tokens by
matching window patterns, using the absolute ENINs in each device's count
snapshot. That window pattern is exactly the data the owner authorized. The
backup exclusion is what keeps it on the device.

**Tests that pin this** are listed in §7. The main one is
`SigilPresenceNeverLeavesDeviceTests`, modelled on
`SignalStrengthNeverRecordedTests.swift:9-53`.

---

## 4. Existing records (question E)

- **"No data" is the absence of a row for the `proofId`.** There is no sentinel
  row and no empty text. One pure lookup returns `nil` in three cases: no row, a
  decode failure, or a builder failure. `RecordSigilSlot` given `nil` draws
  today's ring (`RecordSigilSlot.swift:35-38`).
- These records get `nil`: every record written before phase 2, killed
  sessions, sessions with more than 1,024 peers, records restored from backup,
  and screenshot or UI-test fixture records that do not go through the shared
  builder.
- **Nothing is inferred.** Neither the migration nor the view reads snapshot
  counts, `Proof.peersVerified` (`Proof.swift:19`), `WindowReport.peerCount`
  (`WindowReport.swift:16`) or `gradientSeed` (`Proof.swift:20`) to make a
  Sigil. `RecordingView.swift:95-96` already states this for the sealed frame.
- **A row with P = 0 is data, not absence.** This happens when every B003 read
  in the session failed and the record came through the co-presence arm
  (`SensingCoordinator.swift:275-283`). It draws rings and the centre dot, and
  VoiceOver says "0 mutual, 0 detected, window W". That matches the record's
  `deviceCount`, which is also 0.

---

## 5. Both OS (question F)

| Layer | Phase 2 | Later |
| --- | --- | --- |
| `shared/` | Codec, builder and `commonTest`. These also run in `:shared:testAndroidHostTest`. | v2 format if presence 2 ever has evidence (OD-7) |
| iOS | Store, `SensingCoordinator` wiring, `RecordSigilSlot` and its callers (§6) | Record-delete path (proposed issue) |
| Android | **Production untouched.** It has no Sigil surface: `git grep -i sigil -- android` returns 0 hits, and there is no `RecordSigilSlot` counterpart. Flat 2b is iOS-first (DECISIONS 2026-09-22, line 1674). The phase 2 PR must say this under the Both-OS rule. | Build a Sigil surface, then call the same shared builder from `AggregationRuntime.kt:14-21` / `EventJoinCoordinator.kt:1040-1047`. **Before** persisting anything, exclude the file from Auto Backup (`allowBackup="true"`, `AndroidManifest.xml:16`, with no extraction rules). |

**Proposed issues (not created):**
1. "Android: draw record Sigils from on-device presence (#653 parity), excluded
   from Auto Backup". Related to #337.
2. "Delete a record and all of its on-device data (no deletion path exists on
   either OS)".
3. Optional, outside #653: "Stores in Documents are included in iCloud/Finder
   backups (window reports, pending RPID captures)". See §3.

---

## 6. UI (question G)

`RecordSigilSlot` had six call sites at `62531fe`. Frame numbers are taken
from the views themselves. A seventh, frame 12's session-proof row, arrived
with #701 when `design/flat-2b` was merged in (`d9190b5`). It is the last row
of this table and is migrated to the same API.

| Frame | Call site | Size | Page ground | Variant | Source | Draws |
| --- | --- | --- | --- | --- | --- | --- |
| 04 active card | `CollectionHomeView.swift:266` | 84 | ink | full | **Live**, in memory (OD-8) | Detected-only rings, dots and thin lines. Neutral until `currentProofID` exists (`SensingCoordinator.swift:324`). |
| 04 past row | `CollectionHomeView.swift:351` | 60 | canvas | **mini** | Store (representative proof) | See the mini note below |
| 06 sealed | `RecordingView.swift:116` (`SensingSealedView`) | 300 (`Tokens.swift:138`) | ink | full | Store. It is written before 06 is built (`AppCoordinator.swift:973-988`). | Detected-only full Sigil |
| 07 Proof Collected | `ProofCollectedView.swift:86` | 290 | canvas | full | Store | Detected-only full Sigil |
| 08 event rows | `EventDetailView.swift:341` | 72 − 24 = **48** (`Tokens.swift:167`, `:83`) | canvas | **mini** | Store | See the mini note below |
| 09 Proof Detail | `ItemDetailView.swift:118` | 200 (`Tokens.swift:140`) | canvas | full | Store | Detected-only full Sigil |
| 12 report session-proof row | `ReportDetailView.swift` `sessionProofRow` (`.reportDetailRow`) | 40 | canvas | **mini** | Store | See the mini note below |

- **Ground, measured (OD-6).** Measured from the Figma exports on disk, in
  place: each frame's `meta.xml` node, and the fill of its Sigil SVG asset. The
  ring radii also confirm each ground: the outer ring sits at `0.41 × size` on a
  disc and at `0.46 × size` without one (`SigilLayout.kt:81`, `:84`). All of it
  now lives in one place, `RecordSigilPlacement`, and is pinned by literal
  tests.

  | Frame | Figma node (file) | Evidence | Sigil ground | Page |
  | --- | --- | --- | --- | --- |
  | 04 active card | `183:13` "mini sigil" 84×84 (`issue-635-home/build/flat2b-figma/04/04.meta.xml`, asset `a2fcc.svg`) | No ground path; marks `stroke="white"` | `NONE` | ink |
  | 04 / 04c past row | `183:54`, `203:47` 60×60 (`04/04.meta.xml`, `04c/04c.meta.xml`; assets `27c20.svg`, `f7e42.svg`) | No ground; marks `#0B0B0F` | `NONE` | canvas |
  | 06 sealed | `184:65` 300×300 (`issue-636-sensing/build/flat2b-figma/06/06.meta.xml`, asset `cbc12.svg`) | First path is the inner ring (r 45 = 0.15 × 300); outer ring r 138 = 0.46 × 300; frame ground `--ink` | `NONE` | ink |
  | 07 Proof Collected | `183:222` 290×290, ground `183:223` (`07/07.meta.xml`, asset `992c4.svg`) | Full 290 circle `fill="#0B0B0F"`; outer ring r 118.9 = 0.41 × 290 | `DISC` | canvas |
  | 08 event rows | `184:266`, `184:305` 48×48 (`issue-635-home/build/flat2b-figma/08/08.meta.xml`, asset `5a3f4.svg`) | No ground; marks `#0B0B0F` | `NONE` | canvas |
  | 09 Proof Detail | `204:36` 200×200 (`issue-636-sensing/build/flat2b-figma/09/09.meta.xml`, asset `dfa3a.svg`) | Full 200 circle `fill="#0B0B0F"`; inner ring r 30 = 0.15 × 200 | `DISC` | canvas |
  | 12 report session-proof row | `206:174`, `206:213` 40×40 (`issue-635-home/build/flat2b-figma/12/12.meta.xml`, assets `283bc.svg`, `56c54.svg`) | No ground; `#0B0B0F` strokes of width 2; the only filled path is the r 3.2 centre dot | `NONE` | canvas |

  The **native color gap** is fixed. `SigilDrawing.inkRole` used to paint
  marks `bg` only on `DISC` (`SigilView.swift:98-110`), so on the ink-page
  frames (04 active card, 06) a `NONE` Sigil would have been black on black.
  It now takes the page as well: a mark is `bg` on a disc or on an ink page,
  following DESIGN.md §5, "text and Sigil on `ink`" (`DESIGN.md:608-609`). This
  is a color change only and moves no geometry.

  **Two Figma differences, recorded and not acted on** (both belong to
  #633's layout and palette, not to #653's data):
  - Figma draws 04's 84 pt card in the **mini** style: strands only, stroke 2.
    `layoutSigil` draws the full variant above 60 (`SigilLayout.kt:458`), so the
    84 pt card shows rings, dots and thin detected lines.
  - Figma uses **three** tones: rings `#2A2A31`, detected marks `#6E6E78` (06:
    `#5C5C66`), mutual marks white. `SigilView` has two roles, `ink` and `bg`
    (`SigilView.swift:32-46`).
- **Minis at 60 and 48.** The mini draws only presence-2 strands and isolated
  presence-2 points, plus the centre dot (`SigilLayout.kt:458-482`). With no
  presence 2, **every mini is the centre dot alone.**
  - Proposal: draw exactly that for records that have data, and keep the ring
    for records without data.
  - Why this is honest: it is the shared layout's own output for measured
    data. It shows zero mutual strands because zero were established. That is
    the same principle the owner chose for `MUTUAL 0` (DECISIONS 2026-09-26,
    line 2089). The VoiceOver summary still carries the detected count.
  - The cost: every mini with data looks the same. Only presence 2, or a
    spec §5.2 change by the designer, removes that (OD-3). A native "draw
    something else at mini size" branch is forbidden: the variant is decided
    in shared.
- **In progress (04 active card).** The card is drawn live from the in-memory
  session with the same builder that writes the row at session end, so the
  live Sigil and the sealed one cannot disagree. It redraws on each
  `sessionAggregate` publish (`SensingCoordinator.swift:312`, `:2148`).
- **Rules.** Only measured values are shown. Nothing marks individual absent
  rows. No mutual mark appears, because none is ever supplied. When a real
  Sigil is drawn, its VoiceOver summary replaces `accessibilityHidden(true)`
  (`RecordSigilSlot.swift:31`, `SigilView.swift:280-282`), as DESIGN.md §13
  requires (`DESIGN.md:2191-2194`). The neutral ring stays hidden.

---

## 7. Test plan and mutation targets (question H)

**Shared: `SigilPresenceTest` (commonTest).** RED is recorded first, per
`kmp-shared-foundation.md:211-213`.
- Round-trip with byte-identical re-encode. Non-canonical, reordered,
  duplicate-rank, out-of-range-rank and unknown-field inputs are all rejected.
- The token equals the supplied random value exactly, whatever the display id.
  The same display id gets different tokens in two sessions, and assignment
  follows first-seen order.
- Display-id-less observations produce no peer. `P == deviceCount` and
  `W == windowCount` of the same input.
- Literal cap vectors: 1,024 peers accepted, 1,025 fail with `too_many_peers`.
  A duplicate token fails. A token that is not 32 hex characters fails.
- The v1 decoder rejects any presence other than the implicit 1, and the layout
  built from decoded data has `mutualPeerCount == 0`.

**iOS: `SigilPresenceNeverLeavesDeviceTests`.** It uses the behavioural and
structural strategies from `SignalStrengthNeverRecordedTests.swift:30-53`,
paired with positive anchors.
1. Drive a real session through `handleDetection` with distinctive display ids,
   then stop. Read the tokens back from the store as probes. Positive anchor:
   the row exists, `P == deviceCount`, and the probes appear in no input.
2. Byte-search the ledger, window reports, submission captures and records,
   self-proof, binding and count-snapshot files, and the submission payload,
   for every token and display id in both text and UTF-8-hex form. Use the
   guarded `containsValueOccurrence`, because of the UUID lesson at
   `SignalStrengthNeverRecordedTests.swift:93-124`.
3. Extend the existing byte-for-byte reconstruction of the signed window
   payload (`:968`) to the new session.
4. The presence file contains no display id and no RPID.
5. Tokens differ across two records made from identical display ids.
6. The presence file's `isExcludedFromBackup` is `true`.
7. The codec emits only `{header, windows, peers, peer, end}`.
8. A source walk finds no `peerAt(` in production (the only way to read a
   token back out of a layout), and the new store's error enum carries no
   payload.
9. `resetSessionState` drops the session object.
10. `resetForUITesting` clears the store.

**As built, the iOS tests are:**
- `SigilPresenceNeverLeavesDeviceTests`: items 1–9 above.
- `SigilPresenceStoreTests`: item 10, plus round-trip, conflicts, `remove`,
  quarantine and backup marking on every write.
- `RecordSigilPresentationTests`: the presentation list below.

Two items changed shape in the build:
- Item 9 is witnessed by behavior: a second record of the same devices gets
  disjoint tokens, and the live Sigil is `nil` after `reset()`.
- The manual leak mutation (last bullet under "Mutation targets") is **not
  done yet**: it needs an iOS test run, which the PM owns.

**iOS: presentation tests.**
- The lookup returns `nil` for no row, for corrupt text and for an overflowed
  session, and the ring is shown.
- A literal frame→(size, ground) table test covers 84/60/300/290/48/200.
- `inkRole` returns `bg` for marks on an ink page.
- The VoiceOver string is "0 mutual, N detected, window W", with N and W equal
  to the record's snapshot values.

**Mutation targets.** `scripts/mutation_check.py` reaches Kotlin integer
literals, comparisons and booleans only (#662; DECISIONS 1798), and no Swift at
all.
- New Kotlin: the header version `1`, token length `32` and byte count `16`,
  the cap comparisons (`>=` / `>`), the rank arithmetic, the duplicate-token
  check, and the `isSuccess` booleans. All are reachable, and each has a
  literal vector above so it cannot survive by reference.
- Double constants are not mutated, and the new shared code adds none. The mini
  threshold `60.0` is already pinned by literal sizes 60.0 and 60.000001
  (`SigilLayoutTest.kt:540-542`). The 1,024 peer cap is pinned at
  `SigilLayoutTest.kt:718-719`.
- Swift literals (the sizes, the backup flag, the color role) are pinned only
  by the literal tests above. One manual leak mutation per containment test
  (for example, put a token into `WindowReport`) is recorded as RED evidence,
  in the `compile-fixtures/` manual style.
- The full covering suites are run for every modified file, per AGENTS.md.

**Mutation result, as built.** `scripts/mutation_check.py` was run on
`SigilPresence.kt` against `:shared:testAndroidHostTest`. It covered 72 sites:
65 were killed and 7 survived. One survivor was the `too_many_windows`
comparison. It is reachable at exactly 100,000 windows, so the test
`oneHundredThousandWindowsAreAccepted` was added, and a rerun killed it. The 6
that remain protect nothing a test can observe:
- Two are equivalent. The parser's `cursor < lines.size` and
  `rank < windowCount` checks, when relaxed, still reject the same input as
  `invalid_snapshot`: the first through the caught out-of-bounds read, the
  second through `addSigilPresence`'s own window check.
- Four are unreachable defensive branches, each `false` → `true` on a failure
  path:
  - `toSigilInput() == null` after validation, in both the builder and the
    decoder;
  - the encode-side byte cap, since the worst real record is about 0.64 MB;
  - a shrinking observation list, which is append-only.

---

## 8. Open decisions

**All nine were decided by the PM on 2026-09-27:** OD-1 (a), OD-2 (a), OD-3
(a), OD-4 (a), OD-5 Option 2, OD-6 measured from Figma (§6), OD-7 (a), OD-8
(a), OD-9 (a). The table keeps the options as they were weighed.

| # | Decision | Options | Recommendation |
| --- | --- | --- | --- |
| OD-1 | Token | (a) random per record; (b) HMAC(display id) with a per-event-code salt in the Keychain (`ThisDeviceOnly`), so the same peer keeps the same angle across records of one event; (c) raw display id | **(a)**. (b) links records by design, needs a Keychain item that survives uninstall, and depends on the salt never sitting next to the data. (c) is rejected. |
| OD-2 | Window axis | (a) rank over observed windows, `W` = snapshot `windowCount`; (b) full ENIN span, including empty windows | **(a)**. The VoiceOver "window W" then matches every other "window" figure on screen. Cost: gaps are not drawn. |
| OD-3 | Mini (≤ 60) content | (a) the layout's output (centre dot); (b) the neutral ring for every mini; (c) ask the designer for a detected-only mini, which changes spec §5.2 / #633 | **(a) now; raise (c) with the designer.** (b) would claim "no data" for records that have data. |
| OD-4 | Over 1,024 peers | (a) write nothing, show the ring; (b) keep the first 1,024 and mark the record truncated, which needs "at least" VoiceOver copy | **(a)**. Fail-closed, like `SigilLayout` invariant 6 (`SigilLayout.kt:63-68`). Revisit if field data shows sessions of that size. |
| OD-5 | Storage | Option 1 or Option 2 (§2) | **Option 2** |
| OD-6 | Ground per frame | `DISC` vs `NONE` at 07 (290) and 09 (200). #633 names "Proof Collected 黒ベタ円 290 / Proof Detail 240", but frame 09 is 200 today. | **Measured** (§6): 07 and 09 are `DISC`; 04, 04c, 06, 08 and 12 are `NONE`; 04's card and 06 sit on an ink page |
| OD-7 | Presence 2 | (a) v1 never writes 2, and a future format version plus an owner decision covers keeping a (window, RPID)→token map until a #144 Stage 4 statement arrives; (b) design that retention now | **(a)**. Keeping that map is a new retention of RPIDs, which is outside this authorization. |
| OD-8 | In-progress card | (a) live from memory; (b) neutral until sealed | **(a)**. Same data and same builder. |
| OD-9 | Backup | (a) exclude the new file; (b) follow the existing stores, which are all backed up | **(a)**. It is required by "on the device only". Fixing the older stores is a separate issue (§5). |

---

## Appendix: premises in the brief that the code corrected

1. **There is no deletion path to hook.** The brief assumes deletion "with the
   record; on app reset / Delete all data". iOS has no per-record delete and no
   "Delete all data" (§1.5). Android has none either: its only `clear()` is on
   drafts and wallet hints. Only uninstall removes records.
2. **"On the device only" is not the default.** Every iOS store lives in
   Documents and is backed up. Android sets `allowBackup="true"`. The new file
   has to opt out explicitly (§3).
3. **The display id is not merely event-session-scoped.** It is stable per
   (peer, event code) across sessions and days, and it is served over GATT
   B003. It is 4 bytes, so a salted hash stored next to its salt can be
   enumerated. That is why this design uses random tokens rather than
   HMAC (§1.1).
4. **Restart stability does not matter.** A record never survives an app
   restart: a new session creates a new Proof, and a killed session writes no
   snapshot (§1.1).
5. **The frame list was incomplete.** `RecordingView.swift` hosts frame **06**
   (`SensingSealedView`), not 07. The call sites are 04 (two of them), 06, 07,
   08 and 09 (§6).
6. **Some Sigils would be invisible without a color fix.** Frames 04 (active
   card) and 06 sit on ink, and `SigilView` would draw them black on black
   without the native color-role fix (§6).
7. **The #653 citations have drifted.** The display-id lines are now
   `SensingCoordinator.swift:285-291`, not `278-284`. The issue body and
   DECISIONS line 1741 cite `f9e9251`.

## Appendix B: phase 2 implementation record

These are points where building the design changed or settled something.
Each one is inside the approved scope.

1. **A session is bound to one observation input and scans incrementally.**
   It fails with `input_mismatch` for any other input (invariant 8 in
   `SigilPresence.kt`). Without incremental scanning, the per-detection token
   top-up would rescan every row on every detection.
2. **`too_many_windows` was added as a guard.** It cannot be reached through
   aggregation (at most 100,000 observations), but the builder no longer relies
   on that.
3. **The source walk forbids `peerAt(`, not `peerKey`.** `peerKey:` is a
   legitimate argument label on the aggregation calls, and `peerAt` is the only
   way to read a token back out of a layout.
4. **Initializers.** `SensingCoordinator`'s store initializers take
   `sigilPresenceStore:` and `sigilPresenceTokenSource:` as optional
   parameters, so the 30 existing test call sites compile unchanged. When a
   caller omits the store, it gets an isolated temporary file. Production
   passes the real store through the private convenience initializer.
5. **`RecordSigilSlot` now takes `input:placement:`,** replacing
   `recordID:size:ground:`. `RecordSigilPlacement` holds the measured sizes and
   grounds.
6. **Frames 06 and 07 take the input as a view parameter.** It is resolved in
   `ScanFlowView`, because the `Sendable` snapshot structs cannot hold a Kotlin
   object.
7. **The token source checks the `SecRandomCopyBytes` status.** A failed draw
   assigns nothing; the next observation retries. A record left with an
   untokened peer fails with `missing_token`, so no row is written. A zero
   token is never written.
8. **Logging.** The session-end write logs `SigilPresenceStoreError`, which is
   payload-free by design. A file-system error is logged by type name only.
9. **Decode cache (PM review).** `SigilPresenceStore.sigilInput(proofId:)`
   decodes each row once, keeps the result per `proofId`, and returns the same
   instance on every call. A rejected row is cached as well; a row that does
   not exist yet is not. The cache entry is dropped in `remove(proofId:)` and
   cleared in `resetForUITesting()`. A returned input is read-only; it is only
   ever handed to `layoutSigil`.
10. **Not changed:** the `SessionAggregateSnapshot` format, `WindowReport`, the
   ledger, submission, self-proof, Android, the Welcome hero, and the backup
   state of every existing store.
