# Issue #145 — the publication-scope decisions, and what copy may say

**Status:** decided 2026-09-03 by the repository owner. Binding for
`#291`/`dispatch#17` and `#292`/`dispatch#20` copy, and a constraint on
`#144` and on any future publishing pipeline.

**Read order:** `issue-145-privacy-schema.md` (the audit, PR #306) states
the risks and asks 13 questions. `issue-145-ui-scope-questions.md` (PR
#319) narrows those to the three that block describing scope to a record's
owner. **This file answers them.** It does not define a schema and does
not authorise publishing anything.

## The decisions

| | Decision |
| --- | --- |
| **Q3 — graph boundary** | **No participant-level rows in the public view.** |
| **Q8 — time disclosure** | **Event-relative coarse bucket.** No absolute timestamp at any precision. |
| **Q2 — allowed public outputs** | **An attendance count plus Q8's bucket.** Nothing else. |
| **Q10 — wallet/owner-key/self-proof** | **Ratified: never published.** Was already true in code; now a rule. |

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

**What this decision also settles:** beid's "verified" claim cannot rest
on public recomputation. It rests on an operator or facilitator
attestation. **#144's six tiers must be defined on that basis**, so #144
is downstream of this decision, not parallel to it.

**Why the narrow answer was correct even under uncertainty:** the choice is
asymmetric. Publishing participant-level rows once cannot be undone — the
graph, once out, is out. Committing to aggregate-only can be loosened
later. Being wrong in the narrow direction costs delay; being wrong in the
wide direction costs permanently.

### Why Q8 is not a precision dial

An absolute timestamp is a **join key** against photos, calendars, badge
logs and other people's location history. Coarsening it raises an
attacker's cost; it does not remove the key. An event-relative bucket
removes the key itself. These are different kinds of answer, not two
points on one scale.

Q8 was also conditional on Q3: audit §4.3 flags `enin` as narrowing
presence time on its own, so coarsening `observedAt` while `enin` stays
public would have bought little. `enin` disappears only because Q3 closes
participant-level rows. **The three questions are only answerable in the
order Q3 → Q8 → Q2.**

### Q2's answer is incomplete on purpose

Aggregation protects **cohort size**, not the aggregate form. A named
event with three attendees that publishes "3 attendees, afternoon" has
published a roster. beid's events are tens of people and sometimes fewer,
so this is ordinary operation, not an exotic attack.

**The suppression threshold — the minimum cohort, and the behaviour below
it — is deliberately NOT decided here.** The audit defers it to "a
schema-contract parameter," and that parameter is what decides whether the
privacy promise holds at all.

> **Nothing is blocked by this today only because no publishing pipeline
> exists.** Decide the threshold before any work that actually publishes
> something. Do not skip it on the grounds that "it's only aggregates."

### An open product question this decision creates

Whether Contributor Proof / public observation still carries its intended
value at "a count and a coarse bucket" has not been checked by anyone.
This decision may hollow the feature out. That is a product question, left
open rather than answered — recorded here so it is not discovered later
as a surprise.

### Q10 is about drift, not about today

The exclusion is currently a property of the code (§5.1), not a rule.
Audit §5.2 names the residual path: an unfinalized commitment salt (Q6)
could become a wallet-adjacent link. Ratification converts a property that
holds by accident into a constraint future work must not break.

## What copy may say

Only these three:

1. **Which categories of data could ever be included** — an attendance
   count and an approximate window of participation (Q2/Q3).
2. **At what time precision** — an event-relative window, never a
   timestamp (Q8).
3. **That wallet addresses, owner keys, self-proofs and their stable
   derivatives are never published** (Q10).

## What copy must NOT say

Each depends on a question that remains open. These are as binding as the
decisions above.

| Forbidden claim | Depends on |
| --- | --- |
| "You cannot be identified" | Q11 — cohort size, differencing across releases |
| "This cannot be linked to other events you attend" | Q5 — event-instance / EventCode reuse |
| "Totals are independently verifiable by anyone" | Q1/Q9 — and **false as written**, given Q3 |

Anything stronger repeats the failure this repository has already
corrected twice (#240, #291): showing a claim the system cannot back.

## What this file does not do

It does not define the public schema, authorise a publishing pipeline, or
change `TransparencyView`'s per-record availability rows. Those rows stay
honest placeholders until a pipeline and a verifier exist. What is
unblocked is a **static description of what would ever be included**,
shown regardless of whether any particular record has been published.
