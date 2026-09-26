# Mutation-inspection harness: `scripts/mutation_check.py`

Verified 2026-08-27 against `shared/src/commonMain/kotlin/org/levarac/beid/shared/event/EventWindowFilter.kt`
and `EventInfoStore.kt` on `:shared:testAndroidHostTest`. That remains the
last end-to-end run of the whole tool against a real Gradle test task.

The float operator and the snapshot-based restore (beid#662) were added on
2026-09-23 and verified **only by unit test**, in
`scripts/tests/test_mutation_check.py`, which deliberately never invokes
Gradle — one full suite run per mutation site is what makes this tool
expensive, and a test needing it would never be run. Those tests cover float
site discovery, the perturbation and its invariants, comment/string masking,
the integer operator's unchanged behavior, and a byte-exact
snapshot/mutate/restore cycle on an untracked CRLF file containing non-ASCII
text. Separately, every mutant literal form the float operator produces was
compiled by the Kotlin compiler in `Double` and `Float` contexts with zero
diagnostics. What has **not** happened is an end-to-end run of the float
operator against a Gradle test task on a real target; when someone does one,
record it here.

This is a last-checked record, not a substitute for reading the script's own
`--help`/docstring, which is authoritative for CLI shape and operator
behavior.

## What problem this solves

beid#110: during PR #109's review, "does this test suite actually catch
regressions?" was checked by hand three separate times — break production
code, confirm the relevant test goes red, write down the list of behaviors
verified that way. Each list looked complete. Each time, someone who rebuilt
the check from scratch (never someone who just read the existing list) found
behaviors it had missed. The structural problem: whoever writes the list
shares the blind spots of whoever wrote the code, so re-reading the list
can't surface what the list itself is blind to. One specific blind spot
recurred: a test that asserts against a production constant *by reference*
(`assertEquals(SOME_CONSTANT, actual)`) rather than a literal doesn't go red
when `SOME_CONSTANT`'s value regresses, because the mutation moves both
sides of the assertion at once.

The fix committed to the repo is not a better list — a list is exactly the
artifact that failed three times — but a script that regenerates the answer
from production source every time it runs.

## What it does

Given a target Kotlin file or directory and one or more Gradle test tasks,
the script finds mutable sites in the target by scanning the source text,
copies the bytes of every target file once into a temporary backup
directory, then for each site in turn: applies exactly one mutation, reruns
the given test task(s) with `--rerun-tasks`, records whether any test newly
failed ("killed", with the specific test name(s)) or none did ("survived"),
and restores the file from that byte snapshot before moving to the next
site. It runs an unmutated baseline pass first so pre-existing failing tests
are never counted as evidence a mutation was caught.

Mutation operators:

- Comparison-operator swaps: `==`/`!=`, `<`/`<=`, `>`/`>=`.
- Boolean-literal flips: `true`/`false`.
- Integer-literal perturbation: `N` → `N+1`, preserving an `L`/`l` suffix,
  anywhere in the file's code text — including inside `val`/`const val`
  declarations, not only inside function bodies. This is deliberate: a
  constant declaration is exactly the beid#110 by-reference blind spot's
  site. **This operator is integer literals only.** A literal written with a
  decimal point or an exponent is not touched by it at all — it belongs to
  the float operator below. Reading it as covering every numeric literal is
  what beid#662 was filed about: beid#633's sigil geometry is decided
  entirely by `Double` constants, and a run reporting "99 sites, 99 killed,
  0 survived" had mutated none of them.
- Float-literal perturbation: `Double`/`Float` literals — `12.5`, `1.5f`,
  `0.0`, `0.0001`, `1e3`, `2E-5F`, `1_000.5` — scaled toward zero by a
  factor of `0.9`, preserving an `f`/`F` suffix. `0.0` is the one value
  relative scaling cannot move, so it gets a single absolute special case:
  `0.0` → `1.0`.

### Why the float operator scales down by 10%

The factor and the direction are the substance of this operator, not an
arbitrary nudge:

- **Scaling toward zero keeps the mutant inside `[0, original]`.** So every
  upper-bound validation the original satisfied — an alpha in `0.0..1.0`, a
  fraction, a normalised ratio — the mutant satisfies too. This matters: if
  a mutation tripped a `require(x in 0.0..1.0)`, the run would report
  "killed" because a range check threw, not because any test checks the
  behavior. That is a false sense of protection, which is the exact beid#110
  failure this tool exists to prevent.
- **The change is relative, not absolute.** An absolute nudge is invisible
  on `200.0` and enormous on `0.0001`. The ad-hoc pass written by hand
  during beid#633 used `x * 1.1 + 0.05`; that additive term turns `0.0001`
  into `0.0511`, a 511x change, which is not a plausible wrong value.
- **Sign is preserved for free.** A Kotlin literal as written is never
  negative — a leading `-` is a separate unary-minus token — so the scanner
  only ever sees a non-negative body, and a positive factor keeps it
  non-negative.
- **`1.0`, the special case for `0.0`, is the top of the canonical
  `0.0..1.0` ratio range**, so it stays valid where a ratio is validated
  while being a large change for a coordinate or an angle.

So "survived" for a float site means exactly one thing, and it is narrower
than it looks: **no test pins this value to better than 10% relative.** It
does not mean the value is unchecked in every sense — it means nothing in
the suite noticed a 10% error in it. A float site that survives is worth
reading twice before dismissing, and a float site that is *killed* is only
evidence at that resolution.

### What the scanner does and does not catch

It is a line/regex-based text scanner over Kotlin source with comments and
string/char literals masked out on a best-effort basis — **not** a Kotlin
AST mutation engine. Concretely: string interpolation (`${...}`) is masked
out whole rather than re-entering code mode inside it, so mutable sites
inside an interpolated expression are never found (a missed site, never a
corrupted one); comparison-operator sites additionally require whitespace on
both sides in the source, to avoid mistaking generic-type angle brackets
(`List<Int>`) or the `->` lambda arrow for a comparison, which also means a
comparison written without surrounding spaces will be missed.

Two further misses in the numeric scanners, verified rather than assumed: in
a range literal **only the lower bound is matched**, because the lookbehind
rejects a digit preceded by `.`. `0.0..1.0` yields a site for `0.0` and none
for `1.0`; the integer operator behaves the same way, so `1..10` yields only
a site for `1`. `1.0.toInt()`, by contrast, *is* matched and becomes
`0.9.toInt()`, which is valid Kotlin.

Run `scripts/mutation_check.py --help` for the exact, current wording — that
docstring is the source of truth for these limits, not this doc.

### Restore is from a byte snapshot, not `git checkout --`

Each restore writes the snapshot bytes back, then reads the file back and
compares bytes. Two consequences:

- **It runs against untracked and dirty targets.** A dirty or untracked file
  gets an informational note and the run proceeds; the tool used to refuse
  outright. That refusal made it unusable on brand-new, never-committed code
  — which is exactly the code you are adding tests for. beid#633 had to work
  around it by writing a wrapper that replaced the tool's own `ensure_clean`
  and `restore_file`.
- **A restore that did not land stops the run.** On a mismatch the script
  prints a banner on stderr naming the file, the kept backup directory and
  the exact `cp` command to recover by hand, and exits non-zero without
  attempting another site. A restore that failed silently would leave a
  mutated constant in a source file and nothing would turn red — the same
  class of quiet wrongness the tool exists to catch. The backup directory is
  removed on success and kept, with its location reported, on failure.

## Usage

```sh
scripts/mutation_check.py \
  --target shared/src/commonMain/kotlin/org/levarac/beid/shared/event/EventWindowFilter.kt \
  --test-task :shared:testAndroidHostTest
```

`--target` may also be a directory; every `.kt` file under it is scanned.
`--test-task` accepts a comma-separated list (e.g. a change under
`android/app/src/main` would pass `:app:testDebugUnitTest`, a change under
`shared/src/commonMain` would pass `:shared:testAndroidHostTest`). Both of
those tasks run on the JVM host, so no simulator or device is needed.

The script resolves its own JDK via `scripts/resolve_kmp_java_home.sh` (never
the ambient system Java). It does not configure `ANDROID_HOME` — set that up
the same way you would for any other Android build in this repo (see
`android/README.md`).

Exit status is non-zero if any mutant survives, so this is usable as an
on-demand pass/fail check, not only an informational report. A JSON report
(machine-readable per-site verdicts) is printed to stdout, or written to a
file with `--json-out <path>`.

## Cost / why this is not in `pr-ci.yml`

One full test-suite invocation per mutation site is too expensive to run
unconditionally on every PR — a file with a dozen mutable sites is a dozen
full Gradle test invocations. This is a manually run, on-demand tool for a
developer or reviewer to check out and run against the specific change under
review, not a new CI gate.
