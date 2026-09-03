# Issue #144 — what the six-tier contract requires once #145 forecloses public participant-level data

**Status:** decision-input for `#144` (the six-tier acceptance contract in
`issue-144-attestation-contract.md`); not itself a contract revision, and
not a schema or protocol decision.

**Read order:** `issue-145-ui-scope-decisions.md` (the owner's 2026-09-03
ruling) first — it is binding and this document does not reopen it. Then
`issue-144-attestation-contract.md` (the six-stage contract this narrows).
This document does not re-answer #145's still-open questions (Q1, Q4, the
Q2 suppression threshold) as if they were #144's to decide — it names them
as dependencies for the owner.

## Where the old contract's premise actually breaks, and where it doesn't

The existing contract's Stage 5 defines success as: "the app, report
server, and any independent verifier derive the same result from the same
accepted input," and its §5 walkthrough operationalizes an "independent
verifier" as a technical outsider who can "obtain only published inputs" —
specifically "the published participant observation records" — and replay
the match/derive steps locally. That premise required the fields Stage
3–4 depend on (`observer`, `subject`, `observedRpids`) to eventually be
publishable.

`issue-145-ui-scope-decisions.md`'s Q3 (owner-decided 2026-09-03) forecloses
exactly that: **no participant-level rows in the public view, ever.** Those
are the same three fields the privacy audit (`issue-145-privacy-schema.md`
§4.2–§4.3) flags as the adjacency list and joinable vertices that
reconstruct the event's contact graph. The decision record states this
break directly: *"beid's 'verified' claim cannot rest on public
recomputation. It rests on an operator or facilitator attestation. #144's
six tiers must be defined on that basis."*

**Stages 1 and 2 are unaffected.** Both are on-device/SDK behavior —
independent BLE observation and event-scoped signing — with no publication
assumption baked into their own contract text. Nothing about "who signs
what on which device" changes because a downstream party can no longer
publish the signed result. If anything, #258/#267 (merged 2026-08-23 and
2026-08-26) are *stronger* evidence for these two stages' "already
specified or implemented" rows: #258 landed the iOS submission pipeline
that captures the exact RPID/reporter-RPID set at window close and signs
it through `ReportSubmissionRuntime`'s Barnard-backed cryptography facade
(`SensingCoordinator.closeWindow`, `ios/Beid/Sensing/SensingCoordinator.swift:2159`),
and #267 added cold-launch and background-checkpoint regression coverage
for that same path (`checkpointOpenWindowForBackgrounding`,
`SensingCoordinator.swift:2116`). Android's side of Stages 1–2 is still
absent: per `AGENTS.md`'s current-state paragraph, #121 (which landed on
Android) gave the app a records list reading its own `ProofRecordStore`,
not the unsent-window ledger, and Android still has no production
submission caller to drain that ledger — the Stage 1/2 Android gap is
unchanged, not newly caused by Q3.

**Stage 5, and the §5 walkthrough it anchors, are what actually break.**
The contract's own words — "same result from the same accepted input" —
never specified how an outsider obtains that input; §5 filled the gap by
assuming public download of raw signed Observations. Q3 removes that
assumption permanently, not provisionally. What survives as the only
verification model consistent with Q3 is **attestation**: an operator or
facilitator computes a result over raw input it holds privately, and signs
it; the public can check that signature and whatever the facilitator
chooses to publish (a count and a coarse time bucket, per Q2/Q8) — it
cannot independently re-derive the result from first principles the way
§5 describes. Stages 3, 4, and 6 are downstream of the same shift, because
each assumed a verifier or outsider role that could, in principle, act on
published raw records; each must now be re-read as acting on records an
attesting party holds privately.

## Stage-by-stage

### Stage 1 — A and B independently observe each other

**Verdict: unaffected by Q3.**

Reachable today: Barnard owns BLE/RPID production; iOS's
`SensingCoordinator` accumulates the peer RPID set per window and hands it
to `ReportSubmissionRuntime.captureAndQueueWindow` at window close
(`SensingCoordinator.swift:2172-2182`), evidenced further by #258's
byte-exact capture-before-clear fix and #267's regression coverage of the
same boundary. Depends on no open #145 question. Outstanding gap is
unchanged from the 2026-08-31 contract and is internal to this repository:
Android has no production capture/submission caller (confirmed against
`AGENTS.md`'s 2026-09-03 current-state paragraph — #121 is a records-list
feature reading a separate store, not this path), and there is still no
end-to-end two-device evidence fixture.

### Stage 2 — both devices sign with the event-scoped key

**Verdict: unaffected by Q3.**

Reachable today: Barnard's per-event `KDF(DeviceSecret, EventCode)` signing
key and signature profile, invoked on iOS through the same
`ReportSubmissionRuntime` path that signs and queues each closed window.
Depends on no open #145 question. Gap unchanged: no both-OS wiring, no
published cross-device signature-pair conformance vectors. This stage's
own contract text was never about what becomes public — nothing here
turns on Q3.

### Stage 3 — verify signatures and the time window

**Verdict: partially affected.**

The validation rule itself (bind to event, resolve the signing key,
validate the signature, check the time window) is unchanged by Q3 — it
never depended on public disclosure. What Q3 constrains is *who* is
allowed to be "the verifier": the contract's §5 walkthrough treated an
outside technical verifier as someone who downloads and validates public
records directly. That is no longer available for participant-level
Observations. The only currently-evidenced piece of this stage is
ingestion-time verification the operator already performs — iOS's
receipt handling validates an `AcceptanceReceipt` against the receipt
public key bound in the verified `EventDefinitionContext`
(`SubmissionModels.kt`'s `AcceptanceReceipt` fields: `operatorId`,
`observationDigest`, `context`, `acceptedAt`, `mergeBy`, `policyDigest`).
That proves operator ingestion of one signed Observation; it is not
Stage 3's independent-verifier validation of a reciprocal pair, and this
document does not claim otherwise. Depends on #145 Q1 (does "verifier"
mean a public replayer or an attesting party?) and Q4 (trust model: who
may act as verifier, under what access to private raw input). No evidence
in this repository of a standalone verifier component; only the
ingestion/receipt half is evidenced.

### Stage 4 — match and de-duplicate one mutual observation

**Verdict: partially affected.**

The matching rule (reciprocal A→B and B→A records, same event, compatible
window, exactly one mutual observation, no double-count on replay) is
substantively unchanged. What changes is that the contract's stated
check — "the verifier must be able to recompute and check it rather than
trust it" — assumed a verifier with access to the same raw records the
report-server used. Under Q3, only an attesting party can hold that
access; a public "anyone" cannot. Nothing in this repository implements
report-server-side matching today (unchanged from the 2026-08-31 gap).
Depends on #145 Q4 (who may audit/recompute the match under what access)
and, wherever a natural key or bundle encoding is needed, on the
still-undetermined #108 facilitator specification. No evidence in this
repository of a facilitator/operator matching or deduplication
implementation.

### Stage 5 — every implementation derives the same result

**Verdict: most directly affected.**

This is where the old contract's premise breaks, as described above. The
contract's requirement that "the app, report server, and any
independent verifier derive the same result from the same accepted input"
is not itself false, but its §5 operationalization — a technical outsider
downloading published participant records and replaying the derivation —
is no longer a reachable path. `issue-145-ui-scope-decisions.md` states the
replacement directly: *"beid's 'verified' claim cannot rest on public
recomputation. It rests on an operator or facilitator attestation."*
Nothing in this repository evidences the attestation-producing side of
that model — no facilitator specification, no attestation format, no
signer role beyond the existing ingestion `AcceptanceReceipt`. Depends on
#145 Q1 (verification target — this is now the question that decides what
Stage 5 even means) and on #108 (facilitator specification and conformance
vectors), which as of the original contract's 2026-08-20 note remains
without an identified owner.

### Stage 6 — organizer cannot issue or override a result

**Verdict: partially affected.**

The property itself (no organizer issuance/override path) is unaffected —
it was already going to be enforced by a verifier or facilitator, not by
the organizer. What breaks is the *detection* mechanism the contract's §5
step 8 described: "compare the locally derived result... with the
published server result." Comparing against a public, independently
re-derived result is exactly the capability Q3 removes. Under an
attestation model, detecting an organizer override instead depends on
whatever challenge/audit process the facilitator specification defines —
which is #145 Q4, still open. No evidence in this repository of an
audit/challenge mechanism for an attestation; only the existing role
separation (organizer publishes configuration and runs infrastructure; it
is not documented anywhere as a legitimate participation issuer) carries
forward unchanged.

## Open questions this document surfaces but does not answer

- **#145 Q1 (verification target)** — now load-bearing for Stage 5 in a
  way it may not have seemed before Q3: it decides whether "same result"
  means attestation-signature verification only, or something richer the
  owner still needs to specify.
- **#145 Q4 (trust model)** — governs Stages 3, 4, and 6: who may inspect
  raw private observations, under what challenge/audit process, and what
  signs an aggregate (operator signature, multiple facilitator signatures,
  a committed dataset with openings, or a zero-knowledge proof).
- **#145's Q2 residual (suppression threshold)** — bounds whether Stage 5
  can produce any public output at all for a small event; deliberately not
  decided in `issue-145-ui-scope-decisions.md`.
- **NEW — does the facilitator/operator specification that unblocked
  #108's wire format (the EventDefinition/v1 schema, landed via #258) also
  cover Stage 4 matching/dedup and Stage 6 non-override guarantees, or
  only Stage 2–3 ingestion?** This document and this repository found no
  evidence either way — `EventDefinitionContext` (as consumed by #258)
  supplies submission endpoint, receipt key, operator ID, and event
  validity, none of which is a matching, derivation, or non-override rule.
  This needs confirmation from whoever owns the external facilitator
  specification.
- **NEW — does `dispatch#14`'s completion criterion ("開くと、公開データと
  条件から参加集計を再現できる" — open a verification link and reproduce
  the participation tally from public data) survive Q3 in a weakened,
  signature-check-only form, or does `dispatch#14` itself need
  re-scoping?** Flagged for the product owner; not answered here —
  `dispatch#14` is outside this repository's issue tracker.

## What this must not let future copy, code comments, or the acceptance matrix claim

- Must not claim a third party can independently reproduce a participation
  result from public data. That was true of the raw-Observation model
  Stage 5's §5 assumed; it is false once Q3 stands. At most, a third party
  can check an attestation signature and whatever aggregate the facilitator
  chose to publish.
- Must not treat `ACCEPTED` or any other receipt-derived
  `ReportSubmissionState` as "verified." This repository's own PMO decision
  log already corrected this once: DECISIONS.md, 2026-08-28, "「検証済み」
  は提出フラグとは別の、独立したブロッカーである" — operator acceptance of
  a POST is not third-party verification; that is defined by #144, which
  remains open and unowned. Enabling the submission flag does not produce
  a legitimate "verified" state.
- Must not treat this document's Stage 5 re-reading as authorization to
  implement an attestation pipeline. It is a recommendation and a scope
  narrowing for the owner to rule on, not a decision.

Repeating either failure mode repeats what this repository has already
corrected twice (#240, #291): a claim that outruns what the system can
back.

## Updated acceptance matrix (supersedes the one in `issue-144-attestation-contract.md`, pending owner action)

| Stage | Decision owner | Change since 2026-08-31 | Acceptance status |
| --- | --- | --- | --- |
| 1. Independent sensing | SDK | iOS capture path further evidenced (#258 byte-exact capture-before-clear, #267 regression coverage); unaffected by Q3; Android capture/submission caller still absent | **Partial** — unchanged: Android and two-device fixture missing |
| 2. Independent event-key signatures | SDK | iOS sign-and-queue landed and regression-covered (#258/#267); unaffected by Q3 | **Partial** — unchanged: both-OS wiring and paired verification missing |
| 3. Signature/time verification | verifier | No new verifier implementation; iOS receipt verification against `EventDefinitionContext` further evidenced, but that proves ingestion, not Stage 3 | **Gap, now also depends on an unevidenced external spec** — verifier identity constrained to an attesting party pending Q1/Q4 |
| 4. Reciprocal match/de-dup | report-server | No change; the recompute-and-check assumption in the original contract text now requires attesting-party access rather than public access | **Gap, now also depends on an unevidenced external spec** — matcher absent; recompute access gated by Q4 |
| 5. Identical derivation | verifier | Public-recomputation model in the original §5 walkthrough is closed by Q3; attestation is the only surviving model, per `issue-145-ui-scope-decisions.md` | **BLOCKED** — facilitator spec/owner and conformance vectors absent (#108); now also requires the owner to choose an attestation-based derivation model (Q1) |
| 6. No organizer issuance/override | verifier | No change to the role-separation evidence; the §5 detection mechanism ("compare against a public result") is foreclosed by Q3 | **Gap, now also depends on an unevidenced external spec** — audit/challenge mechanism for an attestation is undefined (Q4) |
