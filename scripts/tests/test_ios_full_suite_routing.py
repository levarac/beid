"""Count planned full iOS suite executions across all jobs in this checkout."""

import json
import math
import os
import re
import shlex
import subprocess
import tempfile
import unittest
from copy import deepcopy
from dataclasses import dataclass
from pathlib import Path
from unittest.mock import Mock, patch

import yaml

from scripts.check_pr_ci_doc_drift import shell_command_lines
from scripts.tests.test_merge_group_workflows import expression_value
from scripts.tests.test_pr_ci_lane_skip import ROOT, WORKFLOWS
from scripts.tests.workflow_yaml import workflow_data

IOS = "pr-ci-ios-macos.yml"
NIGHTLY = "release-ios-nightly.yml"
CORE = "shared/src/commonMain/kotlin/Policy.kt"
VIEW = "ios/Beid/Views/Home.swift"
DOC = "docs/guide.md"
ANDROID = "android/app/src/main/App.kt"


@dataclass(frozen=True)
class Event:
    name: str
    files: tuple[str, ...] = ()
    branch: str = "main"
    action: str = ""
    label: str = ""
    receipt: bool = False  # The evidence verifier's output, tested independently.
    attempt: int = 1
    unsafe: bool = False
    dispatch: str = IOS
    ui_shards: str = ""


def matches(value, patterns):
    """Ordered include/exclude globs used by the workflow trigger filters."""
    matched = False
    for pattern in patterns:
        glob = re.escape(pattern.removeprefix("!")).replace(r"\*\*/", "(?:.*/)?")
        glob = glob.replace(r"\*\*", ".*").replace(r"\*", "[^/]*")
        if re.fullmatch(glob, value):
            matched = not pattern.startswith("!")
    return matched


def triggered(name, on, event):
    if event.name not in ([on] if isinstance(on, str) else on):
        return False
    if event.name == "workflow_dispatch":
        return name == event.dispatch  # Dispatch addresses a single workflow.
    config = on.get(event.name) if isinstance(on, dict) else None
    config = config if isinstance(config, dict) else {}
    if event.name == "push" and config.keys() & {"tags", "tags-ignore"} and not config.keys() & {"branches", "branches-ignore"}:
        return False  # Every push fixture here is a branch push.
    types = config.get("types", ["opened", "reopened", "synchronize"] if event.name == "pull_request" else None)
    return ((not types or event.action in types)
            and ("branches" not in config or matches(event.branch, config["branches"]))
            and not matches(event.branch, config.get("branches-ignore", []))
            and ("paths" not in config or any(matches(path, config["paths"]) for path in event.files))
            and ("paths-ignore" not in config or any(not matches(path, config["paths-ignore"]) for path in event.files)))


def execution_steps(job):
    if job.get("uses", "").startswith("./.github/workflows/"):
        yield {"uses": job["uses"]}
    for step in job.get("steps", []):
        block = step.get("run", "")
        for line in shell_command_lines(block):
            if not re.match(r"^\s*(?:xcrun\s+)?xcodebuild\s", line):
                continue
            args = shlex.split(line)
            if "-enumerate-tests" in args or not {"test", "test-without-building"}.intersection(args):
                continue
            selected = {arg.split(":", 1)[1] for arg in args if arg.startswith("-only-testing:")}
            if (selected and not {"BeidTests", "BeidUITests"} <= selected
                    or any(arg.startswith("-skip-testing:") for arg in args)):
                continue
            yield step


def census(directory):
    owners = {}
    for path in sorted([*directory.glob("*.yml"), *directory.glob("*.yaml")]):
        data = workflow_data(path.read_text())
        jobs = data["jobs"]
        steps = [(job, step) for job in jobs for step in execution_steps(jobs[job])]
        if steps:
            owners[path.name] = (data, steps)
    return owners


def value(expression, event, bindings):
    expression = expression.removeprefix("${{").removesuffix("}}").strip()
    expression = expression.replace("!cancelled()", "True").replace("always()", "True")
    if expression in ("true", "false"):
        return expression == "true"
    ref = {"pull_request": "refs/pull/42/merge", "merge_group": f"refs/heads/gh-readonly-queue/{event.branch}/pr-42"}.get(
        event.name, "refs/heads/" + event.branch)
    return expression_value("(" + expression + ")", event=event.name, ref=ref, attempt=event.attempt,
                            action=event.action, label=event.label, labels=[{"name": event.label}] if event.label else [],
                            bindings=bindings)


def outputs(step, directory, **env):
    path = directory / "output"
    path.write_text("")
    subprocess.run(["bash", "-e", "-o", "pipefail", "-c", step["run"]], check=True, cwd=ROOT,
                   capture_output=True, text=True, env={"PATH": os.environ["PATH"], "RUNNER_TEMP": str(directory),
                   "GITHUB_EVENT_PATH": str(directory / "event.json"), "GITHUB_OUTPUT": str(path), **env})
    return dict(line.split("=", 1) for line in path.read_text().splitlines())


def sharded_plan(workflow, event, directory):
    # Run the classifier and both planning shell steps exactly as the workflow supplies them.
    jobs = workflow["jobs"]
    ctx = {"github.repository": "levarac/beid", "github.event.pull_request.head.repo.full_name": "levarac/beid",
           "inputs.ui_shards": event.ui_shards}
    changes = jobs["changes"]
    active = value(changes["if"], event, ctx)
    (directory / "beid-changed-files.json").write_text(json.dumps({"files": event.files, "ios_force_run": event.unsafe}))
    classify = next(s for s in changes["steps"] if s.get("id") == "classify")
    fields = outputs(classify, directory) if active else {}
    ctx["needs.changes.result"] = "success" if active else "skipped"
    for key in ("ios", "ios_full", "error"):
        ctx[f"steps.classify.outputs.{key}"] = fields.get(key, "")
        ctx[f"needs.changes.outputs.{key}"] = value(changes["outputs"][key], event, ctx)
    plan = jobs["plan"]
    active = value(plan["if"], event, ctx)
    ctx["needs.plan.result"] = "success" if active else "skipped"
    ctx.update({"needs.plan.outputs.mode": "", "needs.plan.outputs.run": ""})
    if active:
        steps = {s["id"]: s for s in plan["steps"] if "id" in s}
        mode = steps["test-mode"]
        allow = value(mode["env"]["ALLOW_SMOKE"], event, ctx)
        labels = [{"name": event.label}] if event.label else []
        (directory / "event.json").write_text(json.dumps({"pull_request": {"labels": labels}}))
        ctx["steps.test-mode.outputs.mode"] = outputs(mode, directory, ALLOW_SMOKE=str(allow).lower(),
                                                     EVENT_NAME=value(mode["env"]["EVENT_NAME"], event, ctx))["mode"]
        eligible = value(steps["previous"]["if"], event, ctx)
        ctx["steps.previous.outputs.previous"] = "verified" if eligible and event.receipt else ""
        matrix = steps["plan"]
        if matrix["env"]["CHANGES_JSON"] != "${{ toJSON(needs.changes) }}":
            raise AssertionError("Matrix must receive the classifier result and outputs")
        planned = outputs(matrix, directory, IOS_UI_SHARDS=str(value(workflow["env"]["IOS_UI_SHARDS"], event, ctx)),
                         EVENT_NAME=value(matrix["env"]["EVENT_NAME"], event, ctx),
                         PREVIOUS=value(matrix["env"]["PREVIOUS"], event, ctx),
                         CHANGES_JSON=json.dumps({"result": ctx["needs.changes.result"], "outputs": fields}))
        ctx.update({f"steps.plan.outputs.{key}": val for key, val in planned.items()})
        for key in ("mode", "run", "matrix"):
            ctx[f"needs.plan.outputs.{key}"] = value(plan["outputs"][key], event, ctx)
    ctx["needs.build.result"] = "success" if value(jobs["build"]["if"], event, ctx) else "skipped"
    return ctx


def whole_suite_copies(job):
    """An unsharded job or reusable call runs the whole suite in each matrix copy."""
    matrix = job.get("strategy", {}).get("matrix", {})
    if isinstance(matrix, dict) and set(matrix) == {"include"} and isinstance(matrix["include"], list):
        return len(matrix["include"])
    if (not isinstance(matrix, dict) or {"include", "exclude"}.intersection(matrix)
            or not all(isinstance(axis, list) for axis in matrix.values())):
        raise AssertionError(f"Cannot count full suite executions in this matrix: {matrix}")
    return math.prod(len(axis) for axis in matrix.values())


def full_executions(workflows, event, *, nightly_run=None):
    """List each full test invocation with its workflow and job, including reusable calls."""
    def walk(name, callers=()):
        if name in callers[::2]:
            raise AssertionError(f"Recursive workflow call: {callers} -> {name}")
        workflow, commands = workflows[name]
        jobs = workflow["jobs"]
        ctx = {"needs.changes.result": "skipped", "needs.changes.outputs.ios": "", "needs.changes.outputs.error": ""}
        if any(step.get("id") == "test-mode" for step in jobs.get("plan", {}).get("steps", [])):
            with tempfile.TemporaryDirectory() as directory:
                ctx = sharded_plan(workflow, event, Path(directory))
        elif any("release_nightly.py decide" in s.get("run", "") for s in jobs.get("plan", {}).get("steps", [])):
            # The nightly's plan is a real decision over fixture observations.
            ctx["needs.plan.outputs.run"] = str(nightly_run).lower()
        for job_id, step in commands:
            job = jobs[job_id]
            if not value(job.get("if", "true"), event, ctx) or not value(step.get("if", "true"), event, ctx):
                continue
            path = (*callers, name, job_id)
            if "uses" in step:
                target = Path(step["uses"]).name
                if target in workflows and "workflow_call" in workflows[target][0]["on"]:
                    for _ in range(whole_suite_copies(job)):
                        yield from walk(target, path)
                continue
            if "scripts.ios_ui_smoke arguments" in step["run"] and ctx.get("needs.plan.outputs.mode") == "smoke":
                continue
            if "scripts.ios_ui_smoke lane-arguments" in step["run"]:
                if job["strategy"]["matrix"] != "${{ fromJSON(needs.plan.outputs.matrix) }}":
                    raise AssertionError("Full test execution must use the planner's matrix")
                expected = ["unit", *(f"ui-{i}" for i in range(1, int(event.ui_shards or "4") + 1))]
                if json.loads(ctx["needs.plan.outputs.matrix"]) != {"lane": expected}:
                    raise AssertionError(f"The full matrix must execute each lane once: {expected}")
                yield path  # The build and all of this matrix's lanes make one full execution.
            else:
                for _ in range(whole_suite_copies(job)):
                    yield path

    return [path for name, (data, _) in workflows.items() if triggered(name, data["on"], event) for path in walk(name)]


class FullSuiteRoutingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflows = census(WORKFLOWS)

    def test_duplicate_full_matrix_in_one_workflow(self):
        workflow = workflow_data((WORKFLOWS / IOS).read_text())
        workflow["jobs"]["second-full-matrix"] = deepcopy(workflow["jobs"]["tests"])
        with tempfile.TemporaryDirectory() as folder:
            (Path(folder) / IOS).write_text(yaml.safe_dump(workflow))
            observed = full_executions(census(Path(folder)), Event("workflow_dispatch"))
        self.assertCountEqual(observed, [(IOS, "tests"), (IOS, "second-full-matrix")])

    def test_manual_dispatch_with_each_shard_count(self):
        workflow = self.workflows[IOS][0]
        choices = workflow["on"]["workflow_dispatch"]["inputs"]["ui_shards"]["options"]
        self.assertCountEqual(choices, ["4", "5"])
        for choice in choices:
            event = Event("workflow_dispatch", ui_shards=choice)
            with self.subTest(ui_shards=choice):
                self.assertEqual(full_executions(self.workflows, event), [(IOS, "tests")])

    def test_event_and_change_matrix(self):
        def pr(*paths, action="synchronize", branch="release/1.1.0", **kwargs):
            return Event("pull_request", paths, action=action, branch=branch, **kwargs)

        cases = [
            ("opened core PR", pr(CORE, action="opened"), 1), ("core update", pr(CORE), 1),
            ("reopened core PR", pr(CORE, action="reopened"), 1),
            ("main core PR", pr(CORE, branch="main"), 1), ("main UI PR", pr(VIEW, branch="main"), 0),
            ("UI PR", pr(VIEW), 0), ("mixed core and UI", pr(VIEW, CORE), 1),
            ("documentation PR", pr(DOC), 0), ("Android app PR", pr(ANDROID), 0),
            ("lab CLI PR", pr("tools/beid-lab-cli/Sources/Lab.swift"), 0),
            ("build configuration PR", pr("android/build.gradle.kts"), 1),
            ("unknown path", pr("unknown/input"), 1), ("failed classification", pr(), 1),
            ("renamed or deleted documentation", pr(DOC, unsafe=True), 1),
            ("full-labelled UI", pr(VIEW, action="labeled", label="ci:full-ui"), 1),
            ("unrelated label", pr(CORE, action="labeled", label="triage"), 0),
            ("closed PR", pr(CORE, action="closed"), 0),
            ("ready with full receipt", pr(CORE, action="ready_for_review", receipt=True), 0),
            ("ready without receipt", pr(CORE, action="ready_for_review"), 1),
            ("eligible synchronize receipt", pr(CORE, DOC, receipt=True), 0),
            ("queue on docs", Event("merge_group", (DOC,), action="checks_requested"), 1),
            ("main fresh push", Event("push", (CORE,)), 1), ("main push with queue receipt", Event("push", (CORE,), receipt=True), 0),
            ("main push rerun", Event("push", (CORE,), receipt=True, attempt=2), 1),
            ("main docs push", Event("push", (DOC,)), 0), ("release cache seed", Event("push", (CORE,), branch="release/1.1.0"), 0),
            ("full dispatch", Event("workflow_dispatch"), 1),
            ("full release dispatch", Event("workflow_dispatch", branch="release/1.1.0"), 1),
            ("unsigned build dispatch", Event("workflow_dispatch", dispatch="main-ios-release-build.yml"), 0),
        ]
        for description, event, count in cases:
            with self.subTest(case=description):
                self.assertEqual(full_executions(self.workflows, event), [(IOS, "tests")] if count else [])

    def test_scheduled_full_count(self):
        if not (WORKFLOWS / NIGHTLY).is_file():
            self.skipTest("release-ios-nightly.yml is absent from this checkout; GitHub runs schedules from main")
        from scripts import release_nightly as nightly

        data = workflow_data((WORKFLOWS / NIGHTLY).read_text())
        plan = data["jobs"]["plan"]
        decide = next(s for s in plan["steps"] if s.get("id") == "decide")
        self.assertIn("release_nightly.py decide", decide["run"])
        self.assertEqual(plan["outputs"]["run"], "${{ steps.decide.outputs.run }}")
        for prior, proof, expected in [("a", None, []), ("b", None, [(NIGHTLY, "full")]), ("b", 41, [])]:
            with self.subTest(previous=prior, proof=proof), patch.object(nightly, "previous", return_value=prior * 40), \
                    patch.object(nightly, "exact_pass", return_value=proof):
                run, _ = nightly.decide(Mock(), "a" * 40, 2, None)
                self.assertEqual(full_executions(self.workflows, Event("schedule"), nightly_run=run), expected)
