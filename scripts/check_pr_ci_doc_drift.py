#!/usr/bin/env python3
"""Fail if AGENTS.md's ### PR CI section drifts from the PR build workflows.

AGENTS.md declares its ### PR CI subsection the single source of truth for
which CI jobs/commands exist, but that subsection is prose restating the
workflow file by hand. This script is the guard rail that keeps the two from
silently diverging (see gh#152): it checks both directions — every job name
and distinguishing command token in the workflow must appear in the doc
section, and every command-shaped token quoted in the doc section must
actually exist in the workflow. It is intentionally narrow (line/regex based,
not a general YAML/Markdown differ) since this is meant to stay simple and
readable, not to become a generic diff tool.
"""
import argparse
import re
import sys
from pathlib import Path

HEADING_RE = re.compile(r"^(#{2,3})\s+(.*)$")
PR_CI_HEADING_RE = re.compile(r"^###\s+PR CI\s*$")

JOB_NAME_LINE_RE = re.compile(r"^ {4}name:\s*(.+?)\s*$", re.MULTILINE)
RUN_LINE_RE = re.compile(r"^(\s*)run:\s*(.*)$")
BLOCK_SCALAR_RE = re.compile(r"^[|>][-+0-9]*\s*$")

GRADLE_TASK_RE = re.compile(r"(?<![\w\[:]):\w[\w:-]*\w")
SCRIPT_PATH_RE = re.compile(r"scripts/\S+\.(?:sh|py)")
BARE_SCRIPT_RE = re.compile(r"^(scripts/\S+\.(?:sh|py))$")

DOC_BULLET_JOB_NAME_RE = re.compile(r"^\s*-\s+([A-Za-z][A-Za-z0-9 /]{1,40}?):\s")
DOC_INLINE_CODE_RE = re.compile(r"`([^`]+)`")
TOP_LEVEL_BULLET_RE = re.compile(r"^-\s")


def extract_pr_ci_section(agents_md_text):
    """Return the text of AGENTS.md's ### PR CI section.

    The section is bounded by the heading and the next ##/### heading (or EOF)
    as an outer limit, but ### PR CI is currently the *last* heading in the
    file, so that outer limit alone would swallow every unrelated bullet that
    follows (TestFlight shipping, versioning, code signing, ...) into "the PR
    CI section" and cause false-positive drift reports on content that was
    never part of the job list.

    The actual job enumeration is confined to the first top-level (zero-
    indent) `- ` list item under the heading — the job list and its
    sub-bullets are indented under it, and the next top-level `- ` item is a
    different, unrelated topic (see AGENTS.md: "- GitHub branch protection
    ..." right after the job list). So within the heading-bounded range, stop
    at the second top-level bullet if one appears before the next heading.
    """
    lines = agents_md_text.splitlines()
    start = None
    for i, line in enumerate(lines):
        if PR_CI_HEADING_RE.match(line):
            start = i
            break
    if start is None:
        raise SystemExit("AGENTS.md has no '### PR CI' heading — cannot check drift.")

    end = len(lines)
    top_level_bullets_seen = 0
    for i in range(start + 1, len(lines)):
        line = lines[i]
        if HEADING_RE.match(line):
            end = i
            break
        if TOP_LEVEL_BULLET_RE.match(line):
            top_level_bullets_seen += 1
            if top_level_bullets_seen == 2:
                end = i
                break

    return "\n".join(lines[start:end])


def collect_run_blocks(workflow_text):
    """Return a list of raw run: content strings, one per `run:` step in the workflow."""
    lines = workflow_text.splitlines()
    blocks = []
    i = 0
    while i < len(lines):
        match = RUN_LINE_RE.match(lines[i])
        if not match:
            i += 1
            continue
        indent, inline = match.group(1), match.group(2)
        if inline and not BLOCK_SCALAR_RE.match(inline):
            # Single-line form: `run: scripts/lint.sh`
            blocks.append(inline.strip())
            i += 1
            continue

        # Block scalar form: `run: |` followed by more-indented lines.
        base_indent = len(indent)
        body_lines = []
        j = i + 1
        while j < len(lines):
            line = lines[j]
            if line.strip() == "":
                body_lines.append("")
                j += 1
                continue
            line_indent = len(line) - len(line.lstrip(" "))
            if line_indent <= base_indent:
                break
            body_lines.append(line.strip())
            j += 1
        blocks.append("\n".join(l for l in body_lines if l))
        i = j

    return blocks


def workflow_job_names(workflow_text):
    return {m.group(1) for m in JOB_NAME_LINE_RE.finditer(workflow_text)}


def workflow_command_tokens(run_blocks):
    """Distinguishing literal command tokens: every Gradle-task-shaped token found
    anywhere in a run: block, plus script paths that are a run: step's *entire*
    (single-line) content — i.e. the job is identified by that bare script
    invocation, the same way `scripts/lint.sh` identifies the SwiftLint job today.
    A script invoked with extra args/flags alongside other setup lines (e.g.
    prepare_testflight_notes.py inside the sanity job) is a supporting step, not
    a distinguishing token, so it is intentionally not swept in here.
    """
    tokens = set()
    for block in run_blocks:
        tokens.update(GRADLE_TASK_RE.findall(block))
        non_empty_lines = [l for l in block.splitlines() if l.strip()]
        if len(non_empty_lines) == 1:
            bare = BARE_SCRIPT_RE.match(non_empty_lines[0].strip())
            if bare:
                tokens.add(bare.group(1))
    return tokens


def forward_check(job_names, command_tokens, section_text):
    """Every workflow-derived token must appear verbatim (job names case-insensitively)
    inside AGENTS.md's ### PR CI section. Returns a list of failure messages."""
    failures = []
    lowered_section = section_text.lower()
    for name in sorted(job_names):
        if name.lower() not in lowered_section:
            failures.append(
                f"AGENTS.md's ### PR CI section is missing job '{name}' "
                f"(present in the checked PR workflows but not mentioned in AGENTS.md). "
                f"Fix: update AGENTS.md's ### PR CI section to mention it."
            )
    for token in sorted(command_tokens):
        if token not in section_text:
            failures.append(
                f"AGENTS.md's ### PR CI section is missing command token '{token}' "
                f"(present in the checked PR workflows but not mentioned in AGENTS.md). "
                f"Fix: update AGENTS.md's ### PR CI section to mention it."
            )
    return failures


def reverse_check(job_names, section_text, workflow_text):
    """Every job-name-shaped bullet and command-shaped inline-code span quoted in
    AGENTS.md's ### PR CI section must correspond to something real in the
    workflow file. Returns a list of failure messages."""
    failures = []
    lowered_job_names = {n.lower() for n in job_names}

    for line in section_text.splitlines():
        bullet = DOC_BULLET_JOB_NAME_RE.match(line)
        if not bullet:
            continue
        candidate = bullet.group(1).strip()
        if candidate.lower() not in lowered_job_names:
            failures.append(
                f"AGENTS.md's ### PR CI section names a job '{candidate}' that does not "
                f"exist in the checked PR workflows (no job with that name). "
                f"Fix: remove/correct it in AGENTS.md, or add the job to the workflow."
            )

    for code_span in DOC_INLINE_CODE_RE.findall(section_text):
        is_gradle_task = bool(GRADLE_TASK_RE.fullmatch(code_span))
        is_script_path = bool(SCRIPT_PATH_RE.fullmatch(code_span))
        if not (is_gradle_task or is_script_path):
            continue
        if code_span not in workflow_text:
            failures.append(
                f"AGENTS.md's ### PR CI section quotes command token '{code_span}' that does "
                f"not appear anywhere in the checked PR workflows. "
                f"Fix: remove/correct it in AGENTS.md, or add it to the workflow."
            )

    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workflow-path", action="append",
                        help="Workflow to check; repeat for multiple workflows")
    parser.add_argument("--agents-md-path", default="AGENTS.md")
    args = parser.parse_args()

    workflow_paths = args.workflow_path or [
        ".github/workflows/pr-ci.yml",
        ".github/workflows/pr-ci-ios-macos.yml",
        ".github/workflows/pr-ci-lab-cli.yml",
    ]
    workflow_text = "\n".join(Path(path).read_text(encoding="utf-8") for path in workflow_paths)
    workflow_description = ", ".join(workflow_paths)
    agents_md_text = Path(args.agents_md_path).read_text(encoding="utf-8")

    section_text = extract_pr_ci_section(agents_md_text)
    job_names = workflow_job_names(workflow_text)
    if not job_names:
        raise SystemExit(f"Found no job 'name:' fields in {workflow_description} — parser bug?")
    run_blocks = collect_run_blocks(workflow_text)
    command_tokens = workflow_command_tokens(run_blocks)

    failures = forward_check(job_names, command_tokens, section_text)
    failures += reverse_check(job_names, section_text, workflow_text)

    if failures:
        print(
            f"AGENTS.md's ### PR CI section has drifted from {workflow_description}:\n",
            file=sys.stderr,
        )
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        print(
            f"\n({len(failures)} issue(s) found. AGENTS.md's ### PR CI section is the "
            "declared single source of truth — see gh#115/gh#152.)",
            file=sys.stderr,
        )
        return 1

    print(
        f"OK: AGENTS.md's ### PR CI section matches {workflow_description} "
        f"({len(workflow_paths)} workflow(s), {len(job_names)} job(s), "
        f"{len(command_tokens)} command token(s) checked)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
