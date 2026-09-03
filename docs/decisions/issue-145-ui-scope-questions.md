# Issue #145 — which of the 13 questions block a UI "publication scope" line

**Status:** decision-input for `#291`/`dispatch#17` and `#292`/`dispatch#20` only;
not a schema or protocol decision

> **Answered.** Questions 2, 3 and 8 were decided by the owner on
> 2026-09-03, and question 10 was ratified. See
> [`issue-145-ui-scope-decisions.md`](issue-145-ui-scope-decisions.md) —
> read it before writing any scope copy, because it also carries the
> claims copy must **not** make and one parameter (the suppression
> threshold) that is deliberately still open.

**Read this before** `docs/decisions/issue-145-privacy-schema.md` (the audit,
PR #306). That document's 13 open questions (§8) gate a public-blob
**implementation**. This one answers a narrower question: which of those 13
must the maintainer decide before the two shipped screens can honestly tell
a user what of their own record would be published? Most of the 13 are
about building the blob; only a few are about describing scope to the
record's owner.

## The constraint every recommendation here respects

§6 (Promise C) walks through a 6-step procedure: group records by
`context`/`enin`, treat `observer` as a pseudonymous vertex, add directed
sighting edges from `observedRpids`, then join records by matching
`subject`. This reconstructs the event's contact graph even though no
field is a name or email (§3, invariant 3). **Pseudonymity is not privacy
when the edges are published.** §7's own table confirms hashing/blinding
"is not aggregation" and "closes neither roster nor graph reconstruction" —
so no recommendation below relies on "the identifiers are opaque."

*(The task brief I received quoted a Japanese sentence attributed to §3.
I checked — the audit file has no Japanese text anywhere. The substance is
accurate and matches §3 invariant 3 / §6 above, cited directly instead of
the unverifiable quote.)*

## Confirming the two screens

- **`DailySummaryView.swift`** (#291): confirmed as described. No
  Verified/public-scope row exists anywhere — removed outright, not shown
  empty, per the type doc comment's #240 citation.
- **`TransparencyView.swift`** (#292): confirmed, with one correction —
  it's two separate always-off items, not one collapsed together: the
  `"Included in published data"` row (last row of the Participation record
  tier) and the entire `"Verified proof"` tier are each independently
  hardcoded `isAvailable: false`. Both are honest placeholders (never a
  fabricated zero) and stay that way until a publishing pipeline and
  verifier exist — this document doesn't change that. What it unblocks is
  a separate, static "what would ever be included" description, shown
  regardless of whether any given record has actually been published yet.

## Minimum decision set: questions 2, 3, 8

Checked the brief's 2/3/8 guess against §3–§8 rather than adopting it —
landed on the same three. Each is load-bearing for *describing* scope, not
for building the blob.

**Q3 — Graph boundary.** §4.2 flags `observer` ("enables a roster of
pseudonymous observers and, with `observedRpids`, graph reconstruction")
and `subject` ("turns raw sightings into joinable directed edges"); §4.3
flags `observedRpids` as "**Critical**... this is an adjacency list."
Options run the §7 spectrum from raw Observations (fails promise C)
through blinded pseudonyms (still reconstructable, per §7) to aggregate-
only or ZK. **Recommend:** commit now to "no participant-level rows in the
public view." **Trade-off:** rules out "blinded" as a future answer —
§7 says that option still permits edge/total recomputation by equal-value
matching — but lets the scope line say "no individual sighting records,
only totals" and stay true regardless of which aggregate mechanism (Q2,
Q9) is picked later.

**Q2 — Allowed public outputs.** Once Q3 forecloses participant-level
rows, this becomes "which totals/histograms, what breakdown" over the
fields §4.2–4.3 already inventory, not "which raw fields." **Recommend:**
narrowest defensible claim — an attendance count plus the coarse time
bucket from Q8 — with suppression thresholds carried as a schema-contract
parameter (§7's closing paragraph). **Trade-off:** less per-window
fraud-replay capability for the public than a richer aggregate would give,
which §7 already frames as inherent to leaving the raw tier.

**Q8 — Time disclosure.** `observedAt` is flagged "exact time enables
external correlation... use a coarser event-relative bucket, epoch, or
omit" (§4.2 field 6); `enin` "narrows presence time" (§4.3 field 2).
**Recommend:** event-relative coarse bucket ("approximate window of
participation," not a timestamp). **Trade-off:** loses second-level/ENIN
timing-replay checks, a capability already conditioned on Q1 (excluded
below).

## Not open, but not silent: question 10

Agree with the brief: Q10 (wallet bindings, self-proofs, owner keys,
wallet addresses, and their stable derivatives are prohibited from public
blobs) isn't actually open. §5.1 states current production code already
keeps `SelfProofRecord`/`BindingRecord` out of `Proof`, `WindowReport`,
`ObservationV1`, and the submission record, and sends `rpidClaim = null`.
§5.2 derives the prohibition from whitepaper invariants (§2), not from
anything under debate. **Treatment:** ratify, don't decide — the scope
line can say today, unconditionally, that wallet/owner-key/self-proof
artifacts are never published. It belongs in neither the decision set
(nothing's blocked) nor the excluded list (it isn't irrelevant — it's one
of the few claims the copy *can* make now). Recording explicit sign-off
also turns §5.2's one named residual risk (an unfinalized commitment salt
becoming a wallet-adjacent link) into a documented constraint on future
commitment-profile work (Q6), not just an inference from present code.

## Excluded, and why

Each bears on building the blob, not on describing scope to the owner.

- **Q1 (verification target):** decides *how* a third party re-derives
  totals, not what fields about the owner's record appear.
- **Q4 (trust model):** who may audit raw private observations — an
  operator-side control, not a fact the scope line states.
- **Q5 (event identity/EventCode reuse):** only matters if the copy
  claims cross-event unlinkability. It doesn't — see the boundary list
  below.
- **Q6 (commitment profile):** moot once Q3 forecloses participant-level
  rows; the commitment field wouldn't appear in an aggregate-only view.
- **Q7 (`rpidClaim`):** already `null` in production (§4.3, §5.1); already
  covered by Q3's "no raw sighting data."
- **Q9 (signature disclosure):** decides how a future aggregate is
  authenticated, not what the owner's data shows publicly.
- **Q11 (release composition):** protects against re-identification
  *across* releases — a stronger property than what one record discloses;
  also the dependency for a boundary claim below.
- **Q12 (metadata/enforcement):** test/retention rigor for whichever
  schema ships; doesn't change what today's copy can say.
- **Q13 (source-of-truth refresh):** a process gate on final adoption
  (§2 already flags the audit's quotations as possibly incomplete).
  Bounds how permanent today's copy should be presented as, not whether
  it can be written.

## Copy boundaries: claims the scope line must not make

Even with Q2/Q3/Q8 answered and Q10 ratified, none of these may appear —
each depends on an excluded question:

- **"You cannot be identified"** — depends on Q11 (cohort size/differencing).
- **"This cannot be linked to other events you attend"** — depends on Q5
  (event-instance/EventCode reuse).
- **"Totals are independently verifiable by anyone"** — depends on Q1/Q9;
  false as written if the eventual design uses operator/facilitator
  attestation rather than public replay.

The only claims the scope line can make once the minimum set is resolved:
what categories of data would ever be included (Q2/Q3), at what time
precision (Q8), and that wallet/owner-key/self-proof artifacts never are
(Q10). Anything stronger repeats the #240/#291 failure mode this
repository has already corrected twice — showing a claim the system
cannot back.
