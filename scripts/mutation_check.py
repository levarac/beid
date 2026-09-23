#!/usr/bin/env python3
"""Mutate real production Kotlin code, rerun tests, report which tests catch it.

beid#110: three rounds of manual "break production code, confirm tests go
red" during PR #109's review each produced a "behaviors verified" list that
looked complete and was later found short by someone who rebuilt the check
from scratch rather than trusting the list. Writing such a list shares the
blind spots of whoever wrote the code being listed, so the fix is not a
better list — it's a tool that *generates* the answer fresh from production
source every time it runs, instead of reading it from anywhere hand-
maintained.

For each mutable site found in --target, this script: mutates exactly that
site, reruns --test-task, records whether any test newly failed ("killed")
or none did ("survived"), then restores the file before moving to the next
site. A survived mutant is a behavior with no test protecting it. Exit status
is non-zero if any mutant survives, so this is usable as an on-demand
pass/fail check, not just an FYI.

Restore is snapshot-based, not `git checkout --`: the bytes of every target
file are copied once, up front, into a temporary backup directory, and each
restore writes those bytes back and then reads the file back and compares
bytes. Two consequences. It runs against untracked and dirty files -- which
is the normal state of work you are adding tests for, and which this tool
previously refused outright. And a restore that did not actually land stops
the run loudly, naming the backup, instead of leaving a mutated constant in
your source tree where nothing turns red.

WHAT THIS IS NOT: a Kotlin AST mutation engine. Site-finding is line/regex
based against Kotlin source text with comments and string/char literals
masked out on a best-effort basis (a hand-rolled state machine, not a real
lexer — nested string interpolation `${...}` is masked out whole, so mutable
sites inside interpolated expressions are never found; this can only cause
missed sites, never a false mutation of string content). Comparison-operator
sites additionally require whitespace on both sides in the original source,
to avoid mistaking generic-type angle brackets (`List<Int>`) or the `->`
lambda arrow for a comparison; a real comparison written without surrounding
spaces will be missed. This is deliberate: err toward missing a mutation
site over corrupting one into invalid syntax.

Known misses in the two numeric scanners, verified rather than assumed: in a
range literal only the lower bound is matched, because the lookbehind rejects
a digit preceded by `.`. `0.0..1.0` yields a site for `0.0` and none for
`1.0`, and `1..10` likewise yields only `1`. `1.0.toInt()`, by contrast, IS
matched, and becomes `0.9.toInt()`, which is valid Kotlin.

Mutation operators:
  - comparison:  ==/!=, </<=, >/>=  (each swapped for its pair)
  - boolean:     true/false literal flips
  - integer:     INTEGER literals only. N -> N+1, preserving an `L`/`l`
                 suffix. A literal written with a decimal point or an
                 exponent is not touched by this operator at all; it belongs
                 to the float operator below. The integer operator applies
                 anywhere in the file text (this includes `val`/`const val`
                 declarations, not just literals inside expressions or
                 function bodies) -- deliberately, since a constant
                 declaration is exactly the beid#110 4th-blind-spot site: a
                 test that compares against a constant *by reference* moves
                 both sides of its own assertion when the constant changes,
                 so it never goes red no matter how wrong the value becomes.
  - float:       Double/Float literals -- `12.5`, `1.5f`, `0.0`, `0.0001`,
                 `1e3`, `2E-5F`, `1_000.5` -- scaled toward zero by a factor
                 of 0.9, preserving an `f`/`F` suffix. 0.0 is the one value
                 relative scaling cannot move, so it gets a single absolute
                 special case: 0.0 -> 1.0.

                 Why scale down by 10%, rather than nudge by a constant:

                 * Scaling toward zero keeps the mutant inside
                   [0, original]. So every upper-bound validation the
                   original satisfied -- an alpha in 0.0..1.0, a fraction, a
                   normalised ratio -- the mutant satisfies too. This
                   matters: if a mutation tripped a `require(x in 0.0..1.0)`,
                   the run would report "killed" because a range check threw,
                   not because any test checks the behavior. That is a false
                   sense of protection, which is the exact beid#110 failure
                   this tool exists to prevent.
                 * The change is relative, not absolute. An absolute nudge is
                   invisible on 200.0 and enormous on 0.0001. (The ad-hoc
                   pass written during beid#633 used `x * 1.1 + 0.05`; that
                   additive term turns 0.0001 into 0.0511, a 511x change,
                   which is not a plausible wrong value.)
                 * Sign is preserved for free. A Kotlin literal as written is
                   never negative -- a leading `-` is a separate unary-minus
                   token -- so the scanner only ever sees a non-negative
                   body, and a positive factor keeps it non-negative.
                 * 1.0, the special case for 0.0, is the top of the canonical
                   0.0..1.0 ratio range, so it stays valid where a ratio is
                   validated, while being a large change for a coordinate or
                   an angle.

                 So "survived" for a float site means exactly one thing, and
                 it is narrower than it looks: NO TEST PINS THIS VALUE TO
                 BETTER THAN 10% RELATIVE. It does not mean the value is
                 unchecked in every sense -- it means nothing in the suite
                 noticed a 10% error in it.

Usage:
  scripts/mutation_check.py --target shared/src/commonMain/kotlin/.../Foo.kt \\
      --test-task :shared:testAndroidHostTest
  scripts/mutation_check.py --target android/app/src/main/kotlin/some/dir \\
      --test-task :app:testDebugUnitTest,:shared:testAndroidHostTest

--target is a file or directory of JVM-testable Kotlin production sources
(shared/src/commonMain or android/app/src/main); --test-task is one or more
comma-separated Gradle test tasks to rerun after each mutation, run via
android/gradlew per this repo's convention (AGENTS.md: "The only Gradle
wrapper is android/gradlew").

This is a manually run, on-demand tool. It is intentionally NOT wired into
.github/workflows/pr-ci.yml: one full test-suite run per mutation site is far
too expensive to run unconditionally on every PR (a file with a dozen
mutable sites is a dozen full Gradle test invocations).
"""
import argparse
import json
import math
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
ANDROID_DIR = REPO_ROOT / "android"
GRADLEW = ANDROID_DIR / "gradlew"
RESOLVE_JAVA_HOME_SCRIPT = REPO_ROOT / "scripts" / "resolve_kmp_java_home.sh"

def display_path(path: Path) -> str:
    """Path relative to REPO_ROOT when it is under it, absolute otherwise.

    `Path.relative_to` raises for a path outside the repository. Calling it
    unguarded crashed the tool on an out-of-tree --target and made the tool
    impossible to unit-test against a temporary directory.
    """
    try:
        return str(path.relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


COMPARISON_SWAP = {
    "==": "!=",
    "!=": "==",
    "<=": "<",
    "<": "<=",
    ">=": ">",
    ">": ">=",
}
# Longest tokens first so `<=`/`>=` win over a bare `<`/`>` at the same start.
COMPARISON_RE = re.compile(r"==|!=|<=|>=|<|>")
BOOLEAN_RE = re.compile(r"\b(true|false)\b")
NUMERIC_RE = re.compile(r"(?<![\w.])(\d[\d_]*)([Ll]?)(?!\w)")
# Group 1 is the numeric body as written (underscores included); group 2 is an
# optional Float suffix. The leading lookbehind is what keeps this scanner and
# NUMERIC_RE off each other's characters: NUMERIC_RE skips a digit run followed
# by `.<digit>`, and this one refuses a digit run preceded by `.` -- so `12.5`
# is a float site and not two integer sites, and `1..10` stays integer-only.
FLOAT_RE = re.compile(
    r"(?<![\w.])"
    r"(\d[\d_]*\.\d[\d_]*(?:[eE][+-]?\d[\d_]*)?"
    r"|\d[\d_]*[eE][+-]?\d[\d_]*"
    r"|\d[\d_]*(?=[fF]))"
    r"([fF]?)"
    r"(?!\w|\.\d)"
)


def perturb_float_literal(body: str):
    """Return the mutated numeric body for a Double/Float literal, or None.

    Scales toward zero by a factor of 0.9 -- see the "float" bullet in this
    module's docstring for why that factor and that direction, which is the
    substance of the operator rather than an arbitrary nudge. 0.0 cannot be
    moved by scaling, so it becomes 1.0.

    `body` is the literal as written, without any `f`/`F` suffix; the caller
    re-attaches the suffix.
    """
    value = float(body.replace("_", ""))
    if not math.isfinite(value):
        return None
    if value == 0.0:
        new_value = 1.0
    else:
        new_value = float(f"{value * 0.9:.12g}")
    text = repr(new_value)
    if "." not in text and "e" not in text and "E" not in text:
        # Defensive. A bare integer token is a type error where a Double is
        # expected, so emitting one would be a compile failure this tool would
        # then misreport as "killed (build failed)". repr() of a Python float
        # never does this today; the guard is here so a future change to this
        # function fails loudly instead of silently emitting broken Kotlin.
        return None
    return text


@dataclass
class Site:
    file: Path  # absolute path
    line: int
    start: int  # absolute char offset into the file's full text
    end: int
    kind: str  # "comparison" | "boolean" | "integer" | "float"
    original: str
    mutated: str

    def label(self) -> str:
        return (
            f"{display_path(self.file)}:{self.line} "
            f"[{self.kind}] {self.original!r} -> {self.mutated!r}"
        )


@dataclass
class SiteResult:
    site: Site
    verdict: str  # "killed" | "survived" | "killed (build failed)"
    killed_by: list = field(default_factory=list)


def mask_source(text: str) -> str:
    """Return text with comment/string/char-literal contents replaced by
    non-matching filler characters, same length as the input so character
    offsets line up. Deliberately conservative: masks the *entire* body of a
    string (including any `${...}` interpolation) rather than trying to
    re-enter code mode inside it.
    """
    out = []
    n = len(text)
    i = 0
    state = "NORMAL"
    while i < n:
        c = text[i]
        two = text[i : i + 2]
        three = text[i : i + 3]
        if state == "NORMAL":
            if two == "//":
                state = "LINE_COMMENT"
                out.append("  ")
                i += 2
                continue
            if two == "/*":
                state = "BLOCK_COMMENT"
                out.append("  ")
                i += 2
                continue
            if three == '"""':
                state = "STRING_TRIPLE"
                out.append('"""')
                i += 3
                continue
            if c == '"':
                state = "STRING_SINGLE"
                out.append('"')
                i += 1
                continue
            if c == "'":
                state = "CHAR_LITERAL"
                out.append("'")
                i += 1
                continue
            out.append(c)
            i += 1
        elif state == "LINE_COMMENT":
            if c == "\n":
                state = "NORMAL"
                out.append("\n")
            else:
                out.append(" ")
            i += 1
        elif state == "BLOCK_COMMENT":
            if two == "*/":
                state = "NORMAL"
                out.append("  ")
                i += 2
                continue
            out.append("\n" if c == "\n" else " ")
            i += 1
        elif state == "STRING_TRIPLE":
            if three == '"""':
                state = "NORMAL"
                out.append('"""')
                i += 3
                continue
            out.append("\n" if c == "\n" else "#")
            i += 1
        elif state == "STRING_SINGLE":
            if c == "\\" and i + 1 < n:
                out.append("##")
                i += 2
                continue
            if c == '"':
                state = "NORMAL"
                out.append('"')
                i += 1
                continue
            if c == "\n":
                # Unterminated on this line (shouldn't happen in valid
                # Kotlin) -- bail back to NORMAL rather than masking the
                # whole rest of the file.
                state = "NORMAL"
                out.append("\n")
                i += 1
                continue
            out.append("#")
            i += 1
        elif state == "CHAR_LITERAL":
            if c == "\\" and i + 1 < n:
                out.append("##")
                i += 2
                continue
            if c == "'":
                state = "NORMAL"
                out.append("'")
                i += 1
                continue
            if c == "\n":
                state = "NORMAL"
                out.append("\n")
                i += 1
                continue
            out.append("#")
            i += 1
    return "".join(out)


def read_source_text(path: Path) -> str:
    """Decode the file's bytes without newline translation.

    `read_text` opens in universal-newlines mode, so a CRLF file would be
    handed to the scanner as LF and every character offset after the first
    line break would be wrong relative to the bytes actually on disk. Sites
    are spliced back into the snapshot's decoded bytes, so both sides have to
    decode the same way.
    """
    return path.read_bytes().decode("utf-8")


def find_sites(path: Path) -> list:
    text = read_source_text(path)
    masked = mask_source(text)
    candidates = []

    for m in COMPARISON_RE.finditer(masked):
        start, end = m.start(), m.end()
        if start == 0 or end >= len(text):
            continue
        if not text[start - 1].isspace() or not text[end].isspace():
            continue  # avoid generics (`List<Int>`) and the `->` arrow
        op = m.group(0)
        candidates.append((start, end, "comparison", op, COMPARISON_SWAP[op]))

    for m in BOOLEAN_RE.finditer(masked):
        op = m.group(1)
        candidates.append((m.start(), m.end(), "boolean", op, "false" if op == "true" else "true"))

    for m in NUMERIC_RE.finditer(masked):
        start, end = m.start(), m.end()
        tail_start = m.end()
        if tail_start < len(text) and text[tail_start] == "." and tail_start + 1 < len(text) and text[tail_start + 1].isdigit():
            continue  # looks like a decimal float; skip rather than corrupt it
        digits, suffix = m.group(1), m.group(2)
        value = int(digits.replace("_", "")) + 1
        candidates.append((start, end, "integer", digits + suffix, f"{value}{suffix}"))

    for m in FLOAT_RE.finditer(masked):
        body, suffix = m.group(1), m.group(2)
        mutated_body = perturb_float_literal(body)
        if mutated_body is None:
            continue
        candidates.append((m.start(), m.end(), "float", body + suffix, mutated_body + suffix))

    candidates.sort(key=lambda c: c[0])
    kept = []
    last_end = -1
    for start, end, kind, original, mutated in candidates:
        if mutated == original:
            # A mutation that changes nothing would be reported as "survived"
            # having tested nothing, and would burn a full Gradle run doing it.
            continue
        if start < last_end:
            continue  # overlapping match from another operator; keep the first
        line = text.count("\n", 0, start) + 1
        kept.append(Site(path, line, start, end, kind, original, mutated))
        last_end = end
    return kept


def run(cmd, cwd=None, env=None, capture=True):
    return subprocess.run(
        cmd,
        cwd=cwd,
        env=env,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
        text=True,
    )


def resolve_java_home() -> str:
    result = run([str(RESOLVE_JAVA_HOME_SCRIPT)])
    if result.returncode != 0:
        sys.stderr.write(
            f"error: could not resolve a supported JDK via {RESOLVE_JAVA_HOME_SCRIPT}:\n"
            f"{result.stdout}\n"
        )
        sys.exit(1)
    return result.stdout.strip().splitlines()[-1]


def git_status_porcelain(rel_path: str) -> str:
    result = run(["git", "status", "--porcelain", "--", rel_path], cwd=REPO_ROOT)
    if result.returncode != 0:
        raise RuntimeError(f"git status failed for {rel_path}:\n{result.stdout}")
    return result.stdout.strip()


@dataclass
class FileSnapshot:
    path: Path
    original_bytes: bytes
    backup_path: Path


def note_if_dirty(file_path: Path):
    """Informational only -- never a refusal.

    This tool used to refuse any file git reported as dirty or untracked,
    because it restored with `git checkout --` and so could only restore what
    git already had. Restore is now from this tool's own byte snapshot, so a
    file that has never been committed -- exactly the state of the work you
    are writing tests for -- is supported. The note still prints, because it
    changes what a `git diff` means while the run is in flight.
    """
    try:
        rel = str(file_path.relative_to(REPO_ROOT))
    except ValueError:
        return  # outside the repository; git has nothing to say about it
    status = git_status_porcelain(rel)
    if status:
        print(
            f"note: {rel} is dirty or untracked (git status: {status!r}). "
            "Proceeding -- restore is from this tool's own byte snapshot, not git."
        )


def snapshot_files(files, backup_dir: Path) -> dict:
    """Copy every target file's bytes into backup_dir, once, up front."""
    snapshots = {}
    for i, f in enumerate(files):
        original_bytes = f.read_bytes()
        backup_path = backup_dir / f"{i:04d}-{f.name}"
        backup_path.write_bytes(original_bytes)
        snapshots[f] = FileSnapshot(f, original_bytes, backup_path)
    return snapshots


def restore(snapshot: FileSnapshot):
    """Write the snapshot back, then read it back and compare bytes.

    The read-back is the point. A restore that silently did not land leaves a
    mutated constant in a source file and nothing turns red -- which is the
    same class of quiet wrongness this whole tool exists to catch.
    """
    snapshot.path.write_bytes(snapshot.original_bytes)
    readback = snapshot.path.read_bytes()
    if readback != snapshot.original_bytes:
        raise RuntimeError(
            f"restore of {display_path(snapshot.path)} did not land: wrote "
            f"{len(snapshot.original_bytes)} byte(s), read back {len(readback)}"
        )


def restore_or_die(snapshot: FileSnapshot, backup_dir: Path):
    try:
        restore(snapshot)
    except Exception as exc:  # including OSError from the write itself
        bar = "!" * 72
        sys.stderr.write(
            f"\n{bar}\n"
            "RESTORE FAILED -- STOPPING NOW.\n"
            "A MUTATED LITERAL MAY STILL BE IN YOUR SOURCE TREE.\n"
            f"  file:   {snapshot.path}\n"
            f"  backup: {snapshot.backup_path}\n"
            f"  reason: {exc}\n"
            "\nRestore it by hand with:\n"
            f"  cp {shlex.quote(str(snapshot.backup_path))} "
            f"{shlex.quote(str(snapshot.path))}\n"
            f"\nThe backup directory has been kept: {backup_dir}\n"
            f"{bar}\n"
        )
        sys.stderr.flush()
        sys.exit(2)


def parse_junit_results(xml_paths):
    """Return {test_id: is_failed} for every <testcase> across the given files.
    test_id is "classname#name", unique enough within one Gradle test task."""
    results = {}
    for xml_path in xml_paths:
        try:
            root = ET.parse(xml_path).getroot()
        except ET.ParseError as exc:
            sys.stderr.write(f"warning: could not parse {xml_path}: {exc}\n")
            continue
        for testcase in root.iter("testcase"):
            classname = testcase.get("classname", "?")
            name = testcase.get("name", "?")
            test_id = f"{classname}#{name}"
            failed = testcase.find("failure") is not None or testcase.find("error") is not None
            results[test_id] = failed
    return results


def fresh_result_xmls(task_names, since: float):
    found = []
    for task_name in sorted(set(task_names)):
        for xml_path in REPO_ROOT.rglob(f"test-results/{task_name}/TEST-*.xml"):
            if ".git" in xml_path.parts:
                continue
            if xml_path.stat().st_mtime >= since:
                found.append(xml_path)
    return found


def run_tests(tasks, env, verbose=False):
    """Run the given Gradle test tasks with --rerun-tasks and return
    (gradle_exit_code, {test_id: is_failed}, [stdout tail on failure])."""
    task_names = [t.rsplit(":", 1)[-1] for t in tasks]
    # Buffer for filesystem mtime resolution; AGENTS.md's evidence traps
    # bullet on --rerun vs --rerun-tasks is exactly about not trusting a
    # prior run's XML, so this checks freshness against our own clock, not
    # just against Gradle's UP-TO-DATE reasoning.
    start = time.time() - 2
    cmd = [str(GRADLEW), *tasks, "--rerun-tasks"]
    if verbose:
        print(f"  $ {' '.join(cmd)} (cwd={ANDROID_DIR})", file=sys.stderr)
    result = run(cmd, cwd=ANDROID_DIR, env=env)
    xmls = fresh_result_xmls(task_names, start)
    if not xmls:
        return result.returncode, None, result.stdout.splitlines()[-40:]
    return result.returncode, parse_junit_results(xmls), None


def collect_targets(target: Path) -> list:
    if target.is_file():
        return [target]
    return sorted(target.rglob("*.kt"))


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--target",
        required=True,
        type=Path,
        help="Kotlin file or directory of production sources to mutate.",
    )
    parser.add_argument(
        "--test-task",
        required=True,
        help="Comma-separated Gradle test task(s) to rerun per mutation, "
        "e.g. :shared:testAndroidHostTest or "
        ":app:testDebugUnitTest,:shared:testAndroidHostTest",
    )
    parser.add_argument(
        "--json-out",
        type=Path,
        default=None,
        help="Write the structured JSON report to this path (default: print to stdout).",
    )
    parser.add_argument("--verbose", action="store_true", help="Print each Gradle invocation.")
    args = parser.parse_args()

    target = args.target.resolve()
    if not target.exists():
        sys.exit(f"error: --target {target} does not exist")
    tasks = [t.strip() for t in args.test_task.split(",") if t.strip()]
    if not tasks:
        sys.exit("error: --test-task must name at least one Gradle task")
    if not GRADLEW.exists():
        sys.exit(f"error: expected Gradle wrapper at {GRADLEW}")

    java_home = resolve_java_home()
    env = dict(os.environ, JAVA_HOME=java_home)
    print(f"Using JAVA_HOME={java_home}")

    files = collect_targets(target)
    if not files:
        sys.exit(f"error: no .kt files found under {target}")

    all_sites = []
    for f in files:
        all_sites.extend(find_sites(f))

    if not all_sites:
        print(
            f"No mutable sites found in {target} "
            "(comparison/boolean/integer-literal/float-literal scan)."
        )
        sys.exit(0)

    print(f"Found {len(all_sites)} mutable site(s) across {len(files)} file(s).")
    print(f"Test task(s): {', '.join(tasks)}\n")

    for f in files:
        note_if_dirty(f)
    backup_dir = Path(tempfile.mkdtemp(prefix="mutation_check-backup-"))
    snapshots = snapshot_files(files, backup_dir)
    print(f"Byte snapshot of {len(files)} target file(s) taken; backups in: {backup_dir}\n")

    print("Running baseline (unmutated) test pass to record pre-existing failures...")
    baseline_rc, baseline_results, baseline_tail = run_tests(tasks, env, args.verbose)
    if baseline_results is None:
        sys.exit(
            "error: baseline test run produced no fresh JUnit XML for "
            f"{tasks} -- cannot proceed (backups kept in {backup_dir}). "
            "Gradle tail:\n" + "\n".join(baseline_tail)
        )
    baseline_failures = {t for t, failed in baseline_results.items() if failed}
    if baseline_failures:
        print(
            f"warning: {len(baseline_failures)} test(s) already fail before any mutation "
            "(pre-existing; these will never count as evidence a mutant was killed):"
        )
        for t in sorted(baseline_failures):
            print(f"  - {t}")
    print()

    site_results = []
    for i, site in enumerate(all_sites, start=1):
        print(f"[{i}/{len(all_sites)}] {site.label()}")
        snapshot = snapshots[site.file]
        # Splice into the snapshot's own decoded bytes, not a fresh read: the
        # offsets were measured against exactly these bytes, and this way a
        # failed restore from a previous site cannot silently compound.
        original_text = snapshot.original_bytes.decode("utf-8")
        mutated_text = original_text[: site.start] + site.mutated + original_text[site.end :]
        try:
            # write_bytes, not write_text: write_text applies newline
            # translation, so a CRLF file would have every line ending
            # silently rewritten as a side effect of one mutated literal.
            site.file.write_bytes(mutated_text.encode("utf-8"))
            rc, results, tail = run_tests(tasks, env, args.verbose)
            if results is None:
                site_results.append(
                    SiteResult(
                        site,
                        "killed (build failed)",
                        [f"gradle exit {rc}, no test XML produced; tail:", *tail],
                    )
                )
                print("  -> killed (build/compile failed)")
                continue
            newly_failed = sorted(
                t for t, failed in results.items() if failed and t not in baseline_failures
            )
            if newly_failed:
                site_results.append(SiteResult(site, "killed", newly_failed))
                print(f"  -> killed by {len(newly_failed)} test(s): {', '.join(newly_failed)}")
            else:
                site_results.append(SiteResult(site, "survived", []))
                print("  -> SURVIVED (no test caught this)")
        finally:
            restore_or_die(snapshot, backup_dir)

    killed = [r for r in site_results if r.verdict.startswith("killed")]
    survived = [r for r in site_results if r.verdict == "survived"]

    print("\n" + "=" * 72)
    print(f"Sites mutated: {len(site_results)}   Killed: {len(killed)}   Survived: {len(survived)}")
    if survived:
        print("\nSurvived (no test protects this behavior):")
        for r in survived:
            print(f"  - {r.site.label()}")
    print("=" * 72)

    report = {
        "target": display_path(target),
        "test_tasks": tasks,
        "baseline_pre_existing_failures": sorted(baseline_failures),
        "sites_mutated": len(site_results),
        "killed": len(killed),
        "survived": len(survived),
        "results": [
            {
                "file": display_path(r.site.file),
                "line": r.site.line,
                "kind": r.site.kind,
                "original": r.site.original,
                "mutated": r.site.mutated,
                "verdict": r.verdict,
                "killed_by": r.killed_by,
            }
            for r in site_results
        ],
    }
    report_json = json.dumps(report, indent=2, ensure_ascii=False)
    if args.json_out:
        args.json_out.write_text(report_json + "\n", encoding="utf-8")
        print(f"\nJSON report written to {args.json_out}")
    else:
        print("\nJSON report:")
        print(report_json)

    # Every restore in the loop above was verified by byte comparison, and a
    # failure would have exited before reaching here, so the backups have done
    # their job and are safe to drop.
    shutil.rmtree(backup_dir, ignore_errors=True)

    sys.exit(1 if survived else 0)


if __name__ == "__main__":
    main()
