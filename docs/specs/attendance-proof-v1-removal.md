# Spec — Remove the superseded AttendanceProof/v1 signing path (gh#196)

Status: **DRAFT — pending PM approval.** The decision to remove has already
been made by the user (2026-08-11), in response to SubPM `a-20260811-005`'s
finding that this path is a live, ungated production feature rather than
dead code (Track G escalation on gh#196, PM confirmed the finding and took
it to the user). This document does not reopen that decision — it defines
the removal's scope and mechanics, per `DECISIONS.md`'s 2026-08-03
no-code-before-approved-spec rule.

Author: SubPM `a-20260811-005`.

## 1. Why removal, not retention

Two independent grounds, both already settled by the record — this is not
a tidiness pass:

1. `DECISIONS.md`'s 2026-07-26 "署名方式(event signing key + wallet
   binding 1回)" entry ratified that per-ENIN window reports are signed by
   the device's own event signing key, and the wallet signs a binding
   **exactly once per event** — and explicitly rejected per-window
   external-wallet `personal_sign` with an approval round-trip each time
   ("ウィンドウごとの外部 wallet personal_sign(毎回承認往復)は却下").
   `ProofSignatureControlsView`'s "Sign this proof" button is precisely
   that rejected pattern: a manual, per-proof `personal_sign` round-trip,
   available to be tapped again for every proof a user has ever collected.
2. gh#33 and `ProofSignature.swift`'s own doc comment state plainly that
   `SignaturePayload` (schema `AttendanceProof/v1`) is "PROVISIONAL — not
   the protocol's self-proof... unconnected to barnard's per-event signing
   key / RPID-ownership proof... No backend/verifier may depend on this
   payload."

Put together: today the button asks a user to approve a wallet signature,
and the artifact it produces is protocol-meaningless by its own author's
declaration — nothing else in the app reads `Proof.signatureState` for
anything besides displaying it back on this same screen, and no
backend/verifier can rely on it because it was explicitly never meant to
be relied on. Removing it stops the app from asking users to approve
something that doesn't do what a signature approval is normally understood
to do.

## 2. What replaces it, and what the user actually loses

The Barnard-conformant binding model (gh#88, shipped and closed) is the
real protocol-level self-proof mechanism now: `BindingMessage` /
`OwnerKeyProvider` / `EventCommitment`, driven once per event via
`EventBindingSheetView`'s connect+binding interstitial during the scan/
recording flow (`SensingCoordinator.beginBinding` / `.completeBinding`,
`ios/Beid/Sensing/SensingCoordinator.swift`). This is the mechanism gh#33's
own doc comment names as what a real self-proof needs to be connected to,
and it now exists and ships.

But it is **not** a button on the Item Detail screen, and this spec does
not add one there. Concretely, after this change:

- `ItemDetailView` (Screen 08) no longer offers any per-proof signing
  action or signature-status readout — no "Sign this proof," no "Signed" /
  "Signing failed" / "Signing declined" status row.
- The proof's binding status is **not** surfaced on this screen either
  before or after this change — `ItemDetailView`'s "Status" row is already
  a fixed, unconditional "Verified" deliberately decoupled from
  `signatureState` (`docs/specs/itemdetail-redesign.md` §5.2), so nothing
  on this screen currently reflects binding status regardless of this
  spec.

Net effect: the screen loses a control that produced a protocol-meaningless
artifact, and gains no new control in its place. Whether Item Detail should
eventually surface real binding/self-proof status is a separate,
forward-looking product question — noted here as a natural follow-up, not
answered by this spec.

## 3. Full removal surface

**Delete outright:**

- `ios/Beid/Views/ProofSignatureControlsView.swift` — the entire file (view
  + all its `#Preview` blocks). Nothing else constructs this view once its
  one call site is gone.
- `ios/Beid/Views/ItemDetailView.swift` — the `BeidPanel { ProofSignatureControlsView(proofId: proof.id) }`
  block. Nothing else in this file depends on it (the adjacent
  `BeidPanel { transparencyRow }` and the Method/Devices-sensed/Status
  panel above it are unrelated and untouched).
- `AppCoordinator.signProof(_:)` (`ios/Beid/Navigation/AppCoordinator.swift`)
  — the entire method. Its only production caller is the view being
  deleted above; grep confirms no other caller exists.
- `ios/BeidTests/ProofSignatureTests.swift`'s two tests that exercise
  `AppCoordinator.signProof` directly:
  `testSignProofIsReentrantSafeWhileAwaitingApproval`,
  `testSignProofRoutesAttendanceProofDigestThroughSelectedConnector`.

**Do NOT delete — must remain, decoded and ignored:**

- `Proof.signatureState: ProofSignatureState` (`ios/Beid/Models/Proof.swift`)
  stays on the model exactly as-is, including its `Codable` key and its
  existing `decodeIfPresent(...) ?? .notRequested` fallback. Per
  `DECISIONS.md`'s 2026-08-09 schema-migration ruling, removing a field
  from a persisted type is exactly what's forbidden until the envelope
  mechanism exists (8/20-post work, per that same decision) — this field
  is out of scope for that reason alone, independent of whether anything
  still writes to it. After this change it simply never transitions away
  from whatever it already was; new proofs default to `.notRequested`
  forever, since nothing calls `signProof` to move it anywhere else.
- `ProofSignatureState`, `SignatureRecord`, and `SignaturePayload`
  (`ios/Beid/Models/ProofSignature.swift`) all stay as **types**, for the
  same Codable-compatibility reason: `ProofSignatureState.signed(SignatureRecord)`
  embeds a `SignatureRecord`, which embeds a `SignaturePayload` — a
  historical local proof that was actually signed before this change must
  still round-trip through `Codable` without failing. None of these three
  types may lose fields, cases, or change shape.
- `ios/BeidTests/ProofSignatureTests.swift`'s tests that exercise `Proof`'s
  own Codable/decode behavior for `signatureState` (not the signing
  action) stay, unmodified — they protect exactly the "keep decoding old
  data" invariant above:
  `testDefaultSignatureStateIsNotRequested`,
  `testUpdateSignatureStatePersistsAcrossReload`,
  `testLoadingStoreSanitizesStrandedAwaitingApprovalToDeferred`,
  `testLoadingStoreSanitizesStrandedConnectingToDeferred`,
  `testUpdateSignatureStateIsNoOpForUnknownProof`,
  `testDecodingProofWithoutSignatureStateKeyDefaultsToNotRequested`,
  `testProofWithSignedStateRoundTripsThroughCodable`.
  (`testUpdateSignatureStatePersistsAcrossReload` and
  `testUpdateSignatureStateIsNoOpForUnknownProof` exercise
  `ProofStore.updateSignatureState(for:to:)` directly, not through
  `signProof` — that method stays too, since it's `ProofStore`'s own
  generic state-mutation API, independent of who calls it. Nothing in this
  spec requires removing it; leaving it unused-by-production-code-but-
  tested is acceptable, since it's a thin, harmless `ProofStore` primitive,
  not a UI surface asking users to do anything.)

**Implementation's call, not required either way:**

- `SignaturePayload.signingDigestHex()` and the private `hash(of:)` helper
  become dead code once `signProof` is gone (nothing else calls them) —
  and, correspondingly,
  `testSignaturePayloadHashIsStableForSameProof`,
  `testSignaturePayloadNonceDiffersBetweenAttempts`,
  `testSigningDigestChangesWhenNonceDiffers`,
  `testSigningDigestIsHexPrefixed`
  test only those two methods. Since removing them doesn't touch any
  persisted shape (they're pure functions, not stored state), whoever
  implements this may either strip them + their tests as dead code, or
  leave them in place as inert, tested utility methods on an
  already-`Codable` type. Either is fine; not deciding this here.

## 4. DESIGN.md update

Two changes, both required, both mechanical:

1. **Remove** the `### Component: ProofSignatureControlsView` entry
   entirely (§10, Component Inventory) — DESIGN.md documents components
   that exist; this one no longer will.
2. **Amend** the 2026-07-28 "Item Detail reskin" decision-log row (§17.C)
   rather than silently superseding it: append a trailing clause noting
   the "`ProofSignatureControlsView`/`ProofSignatureState`/`Proof`/
   `ProofStore` are untouched... pending Option C" claim is superseded —
   Option C landed (gh#88) and the provisional signing path it names was
   removed per gh#196. Add a **new** decision-log row dated with this
   change's actual landing date, status "Adopted," summarizing the
   removal and citing this spec — so the historical row stays intact as a
   record of what was true in July, while the log as a whole no longer
   disagrees with current code.

## 5. Acceptance criteria

1. `ProofSignatureControlsView.swift` no longer exists; `ItemDetailView`
   builds and renders without it, with no visible gap where the panel used
   to be (verify: does removing the `BeidPanel` wrapper leave awkward
   spacing between the Method/Status panel and the Transparency panel, or
   does `VStack(spacing: BeidDesign.Spacing.section)`'s existing spacing
   handle two adjacent panels cleanly with one fewer in between? — a
   two-panel screen already exists elsewhere in this codebase for
   comparison if needed).
2. `AppCoordinator.signProof` no longer exists; `AppCoordinator.swift`
   still compiles (confirm no other code references it).
3. A local build with existing local proof data that has a non-default
   `signatureState` (e.g. `.signed(...)`) still decodes successfully — the
   two Codable round-trip tests named in §3 pass unmodified.
4. `scripts/lint.sh` reports 0 violations.
5. Full `BeidTests` run is green (this removal touches shared model/view
   files, not the ledger/sensing persistence machinery, but per AGENTS.md
   "run the full covering suite for any file you modified" — `Proof.swift`,
   `AppCoordinator.swift`, and `ItemDetailView.swift` all qualify).
6. DESIGN.md's `### Component: ProofSignatureControlsView` entry is gone;
   the decision log no longer contains an unamended claim that the
   component is "untouched."

## 6. Both-OS note

iOS-only. `ProofSignatureControlsView`, `ProofSignature.swift`, and
`AppCoordinator.signProof` are all iOS-only files/types under `ios/Beid`;
no `shared/` change is proposed or required. Android has no equivalent
screen (per AGENTS.md, Android's implemented flow stops before any
post-join UI exists at all) — there is nothing to remove there.

## 7. Explicitly out of scope

- **Designing what, if anything, Item Detail should show about binding/
  self-proof status.** §2 names this as a real, honest gap this removal
  leaves — not something this spec answers.
- **The choice of whether to strip `SignaturePayload`'s now-dead signing
  helper methods** (§3, "implementation's call") — left to the
  implementer, either choice satisfies this spec.
- **Any change to `BindingMessage` / `OwnerKeyProvider` / `EventCommitment`
  or the connect+binding interstitial** — those are shipped, working, and
  untouched by this spec.
