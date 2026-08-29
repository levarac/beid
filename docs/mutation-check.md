# Mutation-inspection harness: `scripts/mutation_check.py`

Verified 2026-08-27 against `shared/src/commonMain/kotlin/org/levarac/beid/shared/event/EventWindowFilter.kt`
and `EventInfoStore.kt` on `:shared:testAndroidHostTest`. This is a
last-checked record, not a substitute for reading the script's own
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
then for each site in turn: confirms the file is git-clean, applies exactly
one mutation, reruns the given test task(s) with `--rerun-tasks`, records
whether any test newly failed ("killed", with the specific test name(s)) or
none did ("survived"), and restores the file with `git checkout --` before
moving to the next site. It runs an unmutated baseline pass first so
pre-existing failing tests are never counted as evidence a mutation was
caught.

Mutation operators:

- Comparison-operator swaps: `==`/`!=`, `<`/`<=`, `>`/`>=`.
- Boolean-literal flips: `true`/`false`.
- Numeric-literal perturbation: `N` → `N+1`, anywhere in the file's code text
  — including inside `val`/`const val` declarations, not only inside
  function bodies. This is deliberate: a constant declaration is exactly the
  beid#110 by-reference blind spot's site.

It is a line/regex-based text scanner over Kotlin source with comments and
string/char literals masked out on a best-effort basis — **not** a Kotlin
AST mutation engine. Concretely: string interpolation (`${...}`) is masked
out whole rather than re-entering code mode inside it, so mutable sites
inside an interpolated expression are never found (a missed site, never a
corrupted one); comparison-operator sites additionally require whitespace on
both sides in the source, to avoid mistaking generic-type angle brackets
(`List<Int>`) or the `->` lambda arrow for a comparison, which also means a
comparison written without surrounding spaces will be missed. Run
`scripts/mutation_check.py --help` for the exact, current wording — that
docstring is the source of truth for these limits, not this doc.

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
