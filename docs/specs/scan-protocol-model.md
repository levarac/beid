# Spec (DRAFT) — Scan protocol model: window/ENIN reporting + event-first wallet binding

Status: **DRAFT — NOT ready for implementation.** Integrates the key roster
(reference "鍵の一覧と役割分担" ID 73) and the 2026-07-23/26/27 decision record.
Binding mechanics are now CONFIRMED (beid#33, 2026-07-23). Finalization is gated on
the remaining next-MTG items (四條さん同席; see §8): **owner key** adoption/design
(whitepaper §3.2) and **census extension** formalization. Purpose: fix the model so
the remaining Scan screens (06a–07) + the wallet/binding step can be redesigned
correctly, and to feed the next MTG.

Owner: PM a-20260725-036.

## 1. Why this spec exists

The Scan flow's remaining screens can't be redesigned as a straight visual reskin:
Figma draws a **linear, finite** flow (05 → 06a → 06b Verifying → 06c Verified →
07 Proof Collected, a 0→100% progress terminating in a "collected" screen), but the
decision record specifies **window/ENIN-based continuous reporting with no explicit
"complete."** They are incompatible at the UX level. This spec fixes the underlying
model so the UI can follow it. (Scan Slice-1 = 05 Sensing shipped separately in
PR #68 as the model-independent subset.)

## 2. Key roster (authoritative — from ID 73)

| Key | Type | State | Role | What leaves the device |
|---|---|---|---|---|
| DeviceSecret | random seed | implemented (`barnard.rpidSeed`) | root of TEK + event signing key | nothing |
| TEK (GAEN) | symmetric 16B, `HKDF(DeviceSecret‖EventCode)` | implemented | seed for RPID = anonymity layer | nothing (raw TEK exposure forbidden) |
| RPID (GAEN) | identifier (derived), `f(TEK, ENIN)` | implemented | rotating pseudonym broadcast over BLE (per-ENIN); non-linkability | RPID itself (public) |
| **event signing key** | key pair secp256k1, `KDF(DeviceSecret, EventCode)` | implemented (barnard#65/#68) | RPID ownership proof (#69) / **per-ENIN report signing (planned)** | public key + signatures |
| **owner key** | key pair (curve TBD) | **concept — whitepaper §3.2, next MTG** | cross-event identity anchor; fixed at event time by commitment from event signing key; wallet's endorsement target | public key + commitment hash |
| **wallet** (endorsement wallet) | key pair EVM, external (Coinbase/MetaMask) | connect implemented | binding (wallet ↔ owner key) + proof endorsement `personal_sign`; does NOT prove physical presence | address + signature |
| anchor EOA | key pair EVM (operational) | v0 (Sepolia testnet) | backend on-chain anchor of time-window batches | transactions |
| SDK transport key | key pair Curve25519 (session) | SDK-managed | wallet deeplink/relay encryption | internal only |

**Design principles (must hold):** 1 key = 1 role (anonymity=TEK / authenticity=event
signing key / continuous identity=owner key / personhood endorsement=wallet); secrets
never leave the device (only public keys, signatures, hashes go on radio/server);
**wallet is never on the event critical path** (high-frequency per-ENIN work uses the
event signing key; wallet at most once per event).

## 3. Reporting model (window/ENIN-based)

- Sensing runs continuously; each ENIN window yields RPID observations of nearby peers.
- Each window's report is signed by the **event signing key** (device, secp256k1) —
  **no wallet, no user approval** (high frequency).
- Reports are sent when a window ends (or on user stop / app background); only unsent
  windows are sent; past reports are never re-sent; force-kill leftovers batch on next
  send. There is **no explicit "complete."** (2026-07-26)
- Report payload contents (RPID observations, signature, commitment fields): **TBD —
  detail per beid#33** and the owner-key/commit design (§5).

## 4. Binding model (event-first, wallet at most once)

- Flow (2026-07-26, overrides the earlier wallet-first order): launch → Bluetooth
  permission → **event detection / event-code entry → event confirmed** → **wallet
  connect + binding signature in ONE round-trip** (SDK `initialActions`; requires the
  event-selection → connect order).
- `connect` = session establishment (permission to learn the address). `binding` = a
  **verifiable signature**, evidence, not just a session. Distinct, but combined into
  one round-trip initially.
- Wallet at most once per event; a different wallet per event is allowed; **no app-wide
  login** — top-level history is rendered from device-held data.

**Binding mechanics — CONFIRMED (beid#33, approved 2026-07-23 with 小野寺さん):**
- **Binding target**: the wallet `personal_sign`s a message "per-event signing pubkey
  `K` belongs to wallet `W`". (How this ties to `owner key` is part of the owner-key
  work — see §5/§8.)
- **Mutual signature**: valid only with BOTH the wallet signature AND the device key's
  countersign — a third party cannot steal the binding without the device holder's consent.
- **Verifiable timestamp**: the signing payload includes a timestamp, so late binding
  is an undeniable fact; verifiers can choose policy (e.g. "accept only binding before
  event end").
- **Timing tier**: default is **join-time binding**. Full post-hoc binding is NOT the
  default (it widens opportunistic attendance-trading); if allowed, it is an explicit
  **late-bound** lower tier that honestly displays reduced evidential weight.
- **1 round-trip**: `connect + binding` combine into one wallet round-trip / one
  approval via Coinbase `initialActions` (MetaMask `connectAndSign` equivalent).
  Requires the event-first order (`guestFirst`) because the binding content
  (`eventCode` + per-event pubkey) can only be built after event confirmation.
- **Limitation (explicit)**: a wallet signature does NOT prove physical on-site
  presence; the timing constraint can't stop premeditated proxy — it only raises the
  bar against opportunistic post-hoc trading (per the whitepaper trust-model chapter).

## 5. Identity & commitment

- Peer sightings carry only `commit = H(event signing key ‖ owner key ‖ salt)` — an
  opaque hash, **no wallet address on the wire**. Contents are revealed only to a later
  verifier (selective disclosure).
- `owner key` is the cross-event identity anchor, fixed at event time by a commitment
  from the event signing key, and is the wallet's endorsement target.
- **owner key design (curve, derivation, rename account key→owner key): TBD —
  whitepaper §3.2, next MTG.** Because `commit` includes owner key, the proof/commit
  model cannot be finalized until this closes.

## 6. Timestamp integrity

- Time truth is NOT the self-reported timestamp (the signer can forge it). It rests on
  **peer's signed sightings** + **batch on-chain inclusion** (anchor EOA).
- Full post-hoc binding is rejected as the default; the binding payload carries a
  **verifiable timestamp** (beid#33, confirmed) so verifiers can enforce a binding-time
  policy, and late binding surfaces as an explicit lower tier (§4).

## 7. Scan UI implications (answers to the survey's 10 reconciliation questions)

From `docs/redesign-scan-survey.md §7`. Model-driven answers where the roster/decisions
settle them; TBD where gated.

1. **Where wallet-connect + binding UI lives (Q1):** a single wallet connect+binding
   step appears **once, right after event-confirmed** (between 06a and continuous
   sensing/reporting) — NOT on the terminal screen. Figma has no frame for it → a new
   interstitial/sheet is needed.
2. **Event detected vs confirmed (Q2):** OPEN — does BLE detection auto-confirm, or is
   there an explicit "confirm you're at this event" action? Recommend an explicit
   confirm, since binding needs an event commitment. **Needs decision.**
3. **Linear vs window model (Q3/Q4/Q5):** replace Figma's finite 0→100%
   verify→verified→terminal with a **continuous window-reporting** UI (ambient "sensing
   & recording, per window"). "Verifying/Verified/Proof Collected" are reframed: there
   is no terminal "complete"; attendance is continuously recorded and later endorsed.
   Exact "proof" semantics: **TBD** (depends on owner-key/commit).
4. **Progress denominator (Q4):** open-ended cumulative count fits window-based
   reporting better than a fixed X-of-Y target. **Confirm during Slice-2 spec.**
5. **Verified == Collected? (Q5):** likely merge into one "recording" state; final
   "proof" is the endorsed attendance, created earlier than today's `.collected`. **TBD**
   pending commit model.
6. **Signal lost resume vs restart (Q6):** window-based accumulation means prior
   windows' reports are already committed → "signal lost" is a transient **pause with
   resume**, not a restart; nothing already-reported is lost.
7. **statusPill / badge states (Q7):** add a "connecting/binding" state; enumerate in
   Slice-2. (`BeidStatusPill` already has automatic/paused.)
8. **Provisional personal_sign (Q8):** the current `ProofSignatureControlsView` +
   `SignaturePayload` (provisional, non-protocol, beid#33) is **replaced** by the
   binding model + per-ENIN event-signing-key reports. Remove the provisional path.
9. **Device event-signing-key wiring (Q9):** wire the already-derived-but-discarded
   `BarnardIdentity.signingPublicKey(eventCode:)` into per-window report signing —
   an implementation gap to close (no new key model required for reports).
10. **Real event/session model (Q10):** introduce a real event/session model (with
    venue) replacing `DemoEvent` across `ScanPhase` — required for 06a's eventCard;
    scope into the Slice-2 implementation.

## 8. Settled vs TBD (for the next MTG)

**Settled:** key roster & roles; event signing key signs per-ENIN reports (no wallet in
the loop); wallet at most once per event via `initialActions`; timestamp truth = peer
sighting + batch anchor; peer sighting carries only the commit hash (no wallet address);
event-first ordering. **Binding mechanics — CONFIRMED (beid#33, 2026-07-23 with 小野寺さん):**
mutual signature (wallet + device countersign), verifiable timestamp in payload,
join-time-default with explicit late-bound lower tier, 1 round-trip via
`initialActions`, wallet ≠ physical-presence proof.

**TBD (gates finalization — next MTG, 四條さん同席):**
- **owner key** adoption/design — curve, derivation, rename (account key → owner key) —
  whitepaper §3.2. Its relationship to the binding target (`per-event key` ↔ `owner key`)
  and to `commit`'s composition must be fixed here.
- **census extension** formalization (scope/definition to be supplied).
- exact **report/commit payload** (depends on owner key).
- event detection **auto-confirm vs explicit confirm** (§7 Q2) — UX call; PM recommends
  explicit.

## 9. Downstream (after finalization)

- **Scan Slice-2 spec** — redesign 06a Event Found → 07 Proof Collected + the new
  wallet-connect/binding interstitial + real event/session model, following this model.
- **Reporting/signing/binding implementation** — wire event signing key into per-window
  reports; connect+binding round-trip; commit/anchor pipeline (backend).

## 10. Open reference

- Key roster: "鍵の一覧と役割分担" ID 73 (2026-07-23).
- beid#33 (binding design), barnard#65/#68 (event signing key), #69 (RPID ownership),
  whitepaper §3.2 (owner key). Next MTG: 5 confirmation points.
