# Review gate — SUSPENDED as of 2026-08-19

**The independent-review requirement below is suspended.** Owner decision,
2026-08-19; recorded in
`DECISIONS.md`. The gate is documented rather than deleted so that what it
caught, and what suspending it costs, stay legible — and so re-enabling it is
a decision rather than a rediscovery.

Why it was suspended: across three consecutive PRs (#216, #221, #223) no
independently dispatched reviewer was ever assigned, while CI stayed green and
mergeable. A gate that is documented but never runs is worse than no gate,
because it gets cited as though it were in force.

For the current required checks, skip conditions, and merge queue
requirements, see [AGENTS.md — PR CI](../AGENTS.md#pr-ci).

Re-enable when either becomes true: a way to dispatch reviewers independently
of the author exists, or a defect reaches a shipped path that an author's own
review missed.

The description below is retained as the definition to restore.

**A review arranged by the author of the work does not satisfy the review
gate. The gate requires a reviewer dispatched independently of the author.**
Request the independent review from the repository maintainer by opening the
PR, then wait for the maintainer's assignment. The author must not select,
invite, or otherwise arrange the reviewer. How the maintainer handles that
request is a maintainer-side operation outside this document. An
author-arranged review is still a useful self-check; report the two artifacts
separately.

This train produced the same distinction twice. On the walking-skeleton
slice, an author-arranged audit found no blockers, while the independently
dispatched review found an ownership hole that allowed an app-local class to
replace the shared type with every existing check still green. On the ledger
slice, an author-arranged audit also passed, while the independent review
found two blockers, including a regression in the shipped App Review path
that produced duplicate durable records. Neither self-check was dishonest and
no implementer did anything wrong: the gap is a structural property of who
selects the reviewer and frames the review, not a judgment about a person.
