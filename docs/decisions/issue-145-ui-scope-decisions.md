# Issue #145 — the publication-scope decisions, and what copy may say

**Status:** partially decided 2026-09-03 by the repository owner, then
corrected by the later maintainer ruling in issue comment `5523509553`
(2026-09-03 18:3x JST) and the
[2026-11-26 v1.1 decision](https://github.com/levarac/beid/issues/145#issuecomment-7187219210).
Binding for
`#291`/`dispatch#17` and `#292`/`dispatch#20` copy, and a constraint on
`#144` and on any future publishing pipeline.

**Read order:** `issue-145-privacy-schema.md` (the audit, PR #306) states
the risks and asks 13 questions. `issue-145-ui-scope-questions.md` (PR
#319) narrows those to the three that block describing scope to a record's
owner. **This file answers them.** It does not define a schema and does
not authorise a new publishing implementation.

> **Chronology / supersession.** The original UI-scope decision below was
> recorded before the 18:3x ruling. That ruling supersedes every inference in
> this record that raw signed Observations are private, that public replay is
> closed, or that verification must rest on an operator/facilitator
> attestation. The DISPLAY decision limits participant-level rows. The
> 2026-11-26 decision records the current public verification page's device
> count and pseudonymous relations at every event size.

## The decisions

| | Decision |
| --- | --- |
| **Q3 — graph boundary** | **No participant-level rows in the public view.** |
| **Q8 — DISPLAY time disclosure** | **Event-relative coarse buckets for observation times.** The published event schedule may use absolute dates and times. |
| **Q2 — v1.1 public DISPLAY outputs** | **Recomputed device count and observed pseudonymous relations, with no minimum cohort.** Q8 still governs displayed time. |
| **Q10 — wallet/owner-key/self-proof** | **Ratified: never published.** Was already true in code; now a rule. |

### The later ruling: API, DISPLAY, and participant notice are separate

The controlling 18:3x ruling resolves the apparent conflict as three separate
contracts:

1. **Public verification API:** `GET /v1/events/:context/verification` returns
   the operator verification envelope containing the raw bytes of signed,
   pairwise Observations. The public profile retains `observer`, `subject`, and
   `observedRpids`; `rpidClaim` is required to be `null`. This is the input from
   which a third party can replay signature, sighting, mutual-edge,
   deduplication, and aggregate checks. This record does not invent a different
   schema or claim that the endpoint is deployed by this repository.
2. **Public DISPLAY:** the public verification page shows the recomputed
   device count and observed relations between pseudonymous devices for
   events of all sizes. There is no minimum cohort or below-threshold
   suppression. Keep raw participant-level rows distinct from that graph.
   Q8 still governs the time labels rendered by the UI.
3. **Before the participant's first upload:** explain that the public
   verification API exposes raw signed Observations, that third parties
   can reconstruct within-event pseudonymous edges, and that counts and
   relations also appear at small events. A record shows one device observing
   another over Bluetooth. A [mutual sighting](issue-144-attestation-contract.md#2-terms)
   requires two independently signed, valid reciprocal records for the same
   event and a compatible window. A record does not establish a person's presence.
   Explain the retention, deletion and contact details in the
   [2026-11-26 notice decision](https://github.com/levarac/beid/issues/468#issuecomment-7187223146).
   Public copies and records anchored to a public blockchain cannot be recalled.

Names, email addresses, wallet/owner-key/self-proof material, and stable
cross-event identifiers or their stable derivatives are prohibited as inputs
to or outputs from this public contract. Event/window RPIDs and per-event
signing keys are deliberately different: they are permitted pseudonyms for
public replay, not a claim of anonymity. Event-code reuse and the commitment
profile still need decisions before cross-event unlinkability can be promised.

### Why Q3 was a choice and not a setting

The fields that let a third party independently recompute a claim
(`observer`, `subject`, `observedRpids`) are the same fields that
reconstruct the event's contact graph. The audit classifies
`observedRpids` as **Critical** — "this is an adjacency list."

The usual escape — make the identifiers opaque — is already ruled out.
Audit §7 states that hashing and blinding are "not aggregation" and close
"neither roster nor graph reconstruction," because equal-value matching
recovers the edges. So this was never a privacy dial. It was a choice
about which property to give up.

**Superseded inference (kept in chronology):** the initial decision inferred
that beid's "verified" claim could not rest on public recomputation and would
instead rest on an operator or facilitator attestation. The later ruling
rejected that inference: raw signed Observations remain public precisely so a
third party can recompute from first principles. The later v1.1 decision records the public page outputs above.

**Residual privacy consequence accepted by the later ruling:** opaque values do
not conceal topology. A downloader can match `subject` and `observedRpids`
within a window and use the per-event `observer` key across windows. RPID
rotation and per-event key derivation limit intended linkage across windows or
events; they do not prevent reconstruction of pseudonymous edges within an
event. Once downloaded, those bytes and reconstructed edges cannot reliably be
recalled from third-party copies.

### Why Q8 is not a precision dial

An absolute timestamp is a **join key** against photos, calendars, badge
logs and other people's location history. Coarsening it raises an
attacker's cost; it does not remove the key. An event-relative bucket
removes the key itself. These are different kinds of answer, not two
points on one scale.

Q8 governs observation times in the public display. Any displayed activity
uses coarse buckets relative to the event. This applies to time labels for
devices, edges, and aggregates derived from their observations. The UI may show
absolute start and end times from the published event schedule because that
schedule is set independently of device activity. The raw verification response
still carries the timing material required by its public profile. Downloadable
evidence retains that timing even when the display uses coarse buckets.

### Q2 in v1.1

The 2026-09-03 document left suppression open. On 2026-11-26 the
maintainer chose to display device counts and observed pseudonymous
relations at every event size. The raw public evidence lets anyone recount
the event, so hiding small counts on the page would suggest protection
that the published data cannot provide. A later release may introduce a
threshold together with a change to what its raw data exposes.

### Q10 is about drift, not about today

The exclusion is currently a property of the code (§5.1), not a rule.
Audit §5.2 names the residual path: an unfinalized commitment salt (Q6)
could become a wallet-adjacent link. Ratification converts a property that
holds by accident into a constraint future work must not break.

## What copy may say

Copy may separately and accurately say:

1. **What the public DISPLAY shows** — recomputed device counts and
   observed pseudonymous relations even at small events. Apply Q8 to
   displayed time and keep raw participant-level rows separate.
2. **What the public verification API returns** — raw signed Observations,
   including event/window pseudonyms and pairwise sighting data needed for
   replay.
3. **That names, email addresses, stable cross-event identifiers, wallet
   addresses, owner keys, self-proofs and their stable
   derivatives are never published** (Q10).
4. **Before first upload** — explain the reconstruction and small-event
   disclosure, device observation rather than personal presence, and
   retention, deletion limits and access/deletion requests to hi@levarac.org.

## What copy must NOT say

Each depends on a question that remains open. These are as binding as the
decisions above.

| Forbidden claim | Depends on |
| --- | --- |
| "You cannot be identified" | Q11 — cohort size, differencing across releases |
| "This cannot be linked to other events you attend" | Q5 — event-instance / EventCode reuse |
| "No contact graph can be reconstructed" | False for raw public Observations; only participant-level DISPLAY rows are suppressed |
| "Deleting it withdraws all copies" | Device deletion leaves sent records in place. Third-party copies and public-chain records cannot be withdrawn. |

Anything stronger repeats the failure this repository has already
corrected twice (#240, #291): showing a claim the system cannot back.

## What this file does not do

It does not define a new public schema, claim a deployed production endpoint,
or change `TransparencyView`'s per-record availability rows. It records the
controlling contract against which the shipping screen, public API, privacy
policy, store filing, and pre-upload notice must each be checked separately.
The threshold decision applies to v1.1. The operator's documented
retention and deletion wording belongs to #468, and the first-upload screen
belongs to dispatch#36. Their implementation and shipping-build evidence
remain separate. The other schema questions in #145 remain open.

The #144 banner is owned by #392. At this checkout it still says the raw
download/replay path is closed, contradicting the controlling ruling; #392
must correct that banner without this document claiming the dependency is
resolved.
