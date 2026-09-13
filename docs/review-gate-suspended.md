# Review gate — SUSPENDED as of 2026-08-19

**The independent-review gate below is suspended. A PR may be merged once CI
is green on its exact head SHA.** Owner decision, 2026-08-19; recorded in
`DECISIONS.md`. The gate is documented rather than deleted so that what it
caught, and what suspending it costs, stay legible — and so re-enabling it is
a decision rather than a rediscovery.

Why it was suspended: across three consecutive PRs (#216, #221, #223) no
independently dispatched reviewer was ever assigned, while CI stayed green and
mergeable. A gate that is documented but never runs is worse than no gate,
because it gets cited as though it were in force.

What suspension does **not** relax: the Xcode Cloud requirement below still
stands in full — verify that the iOS check **exists on the exact head SHA and
succeeded**, not merely that a green check exists somewhere. That check is the
only automated gate left, so treat its absence as a hard stop.

**Carve-out — when absence is configuration rather than a hard stop.** Xcode
Cloud runs `DO_NOT_START_IF_ALL_FILES_MATCH` over a set of path matchers
configured in ASC. A PR whose **every** changed file falls inside that set has
no iOS check **by configuration**, and that absence is not the hard stop above.
Do not re-derive the reasoning per PR — state it, in this form, in the gate
record:

1. **Predicate** — enumerate every path from `gh pr view <n> --json files` at
   the head being merged, and show each one falls inside the exclusion set.
   Give the count (`N of N`).

   **The set itself is defined in ASC and is not restated here as a rule.** As
   read from the ASC API on **2026-09-09** it was {`docs/`, `.github/`,
   `*.md`} — use that to classify the obvious cases without a GUI, but treat it
   as a dated observation rather than as the contract, and **re-read ASC before
   relying on it for any PR whose classification is not obvious**, or whose
   answer would change if a matcher had been added or removed. The ASC GUI is
   the source of truth for workflow settings, as stated elsewhere in this file.
2. **Complement** — state that anything failing (1) is outside the set **by
   definition**, so an iOS-affecting change cannot qualify for this record.
   Do not enumerate what lies outside. The predicate already answers it, and a
   list of the outside is a second, weaker statement of the same rule that can
   go wrong on its own — silently, the first time a new top-level directory
   appears, leaving a reader who trusts the list unable to classify a path that
   is not on it.
3. **Source and control** — name where the configuration was read, and cite a
   control experiment on the same PR if one exists. **A control has to be able
   to come out the other way**; the record cited here before could not, and was
   nonetheless treated as settled.

   **The matcher is evaluated over the PR's cumulative diff against base, not
   over the delta of the individual push.** That is why the predicate in (1) is
   `gh pr view <n> --json files` rather than a `git diff` of the push: a push
   whose own files are *all* inside the exclusion set still starts a build when
   some earlier commit in the same PR touched a file outside it.

   **The measurements behind that sentence — both halves of the control, the
   five registered predictions, why PR #428 could not decide it, and what a
   falsifying observation would look like — live in
   [`docs/xcode-cloud.md`](docs/xcode-cloud.md), which is their source of
   truth.** They are not repeated here: this clause is read on every merge and
   should stay short, while the evidence gains an entry per observation. Cite
   that section rather than restating its contents, and add new observations
   there.

   The transferable part is not the conclusion but the shape: **before citing a
   control, check whether the competing explanation would have produced a
   different result.** If it would not, say so and leave the question open
   rather than recording a conclusion the experiment cannot carry — otherwise
   the next reader inherits a settled-looking answer built on a non-control.
   The same asymmetry applies to one-sided evidence generally: a check that only
   asks whether the allowed set is too small will never find one that is too
   large.
4. **Void clause** — if **any** file at the final head is outside the exclusion
   set, absence of the check is the hard stop again and the remedy is a
   close→reopen retrigger, **not** this record. Re-evaluate (1) at the head SHA
   named in the package, since the file set is a property of the (head, base)
   pair rather than of the PR.

The carve-out interprets a process rule and lifts no technical control — see
the branch-protection note in the PR CI subsection for why there is no
technical control here to lift. Recorded from the lead's ruling on PR #428.

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
