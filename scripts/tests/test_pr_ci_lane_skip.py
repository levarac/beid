"""Documentation-only PRs skip the iOS simulator and lab CLI lanes.

Both lanes keep their exact job names, so the required status contexts are still
created on every PR head and report "skipped" when the lane does not apply.
These tests evaluate each lane's real job-level ``if:`` expression against the
real classifier output, rather than matching strings, so a condition that
quietly stops skipping (or stops failing closed) is caught.
"""

import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from scripts.ci_change_filter import classify

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github/workflows"

IOS = WORKFLOWS / "pr-ci-ios-macos.yml"
LAB_CLI = WORKFLOWS / "pr-ci-lab-cli.yml"
PR_CI = WORKFLOWS / "pr-ci.yml"

DOCS_ONLY = ["docs/sensing-test-guide.md"]
ANDROID_ONLY = ["android/app/src/main/Foo.kt"]
IOS_ONLY = ["ios/Beid/App.swift"]
SHARED = ["shared/src/commonMain/kotlin/Policy.kt"]
LAB_CLI_ONLY = ["tools/beid-lab-cli/Sources/BeidLabCliCore/LabLine.swift"]
WORKFLOW_EDIT = [".github/workflows/pr-ci-ios-macos.yml"]
UNKNOWN = ["new-product-area/config.toml"]


def job_block(path: Path, job_id: str) -> str:
    text = path.read_text(encoding="utf-8")
    jobs = text.split("\njobs:\n", 1)[1]
    blocks = re.split(r"(?m)^  ([\w-]+):\n", jobs)
    return dict(zip(blocks[1::2], blocks[2::2]))[job_id]


def job_name(path: Path, job_id: str) -> str:
    return re.search(r"(?m)^    name: (.+)$", job_block(path, job_id)).group(1).strip()


def job_condition(path: Path, job_id: str) -> str:
    match = re.search(r"(?m)^    if: \$\{\{ (.+) \}\}$", job_block(path, job_id))
    assert match, f"{path.name}:{job_id} has no single-line job-level if"
    return match.group(1)


def evaluate(condition: str, *, event: str, changes_result: str, outputs: dict, cancelled=False) -> bool:
    """Evaluate the small subset of the expression language these ifs use."""
    values = {
        "github.event_name": event,
        "needs.changes.result": changes_result,
    }
    values.update({f"needs.changes.outputs.{key}": value for key, value in outputs.items()})

    def lookup(match: re.Match) -> str:
        # An output that was never set is the empty string, as in Actions.
        return repr(values.get(match.group(0), ""))

    expression = condition.replace("!cancelled()", "(not CANCELLED)")
    expression = re.sub(r"\b(?:github|needs)(?:\.[\w]+)+", lookup, expression)
    expression = expression.replace("&&", " and ").replace("||", " or ")
    expression = re.sub(r"!(?!=)", " not ", expression)
    # eval is acceptable here: the input is this repository's own workflow
    # text (never PR-supplied at test time), with builtins removed.
    return bool(eval(expression, {"__builtins__": {}}, {"CANCELLED": cancelled}))  # noqa: S307


def outputs_for(files: list[str]) -> dict:
    return {key: str(value).lower() for key, value in classify(files).items()}


LANES = {
    "ios": (IOS, "ios-simulator", "iOS simulator"),
    "lab-cli": (LAB_CLI, "lab-cli", "beid-lab-cli build and test"),
}


def lane_runs(lane: str, *, event="pull_request", changes_result="success", files=None, outputs=None) -> bool:
    path, job_id, _ = LANES[lane]
    if outputs is None:
        outputs = outputs_for(files) if files is not None else {}
    return evaluate(job_condition(path, job_id), event=event, changes_result=changes_result, outputs=outputs)


class LaneNamesTest(unittest.TestCase):
    def test_required_check_names_are_unchanged(self):
        for lane, (path, job_id, name) in LANES.items():
            with self.subTest(lane=lane):
                self.assertEqual(job_name(path, job_id), name)

    def test_lanes_are_gated_by_a_job_not_a_workflow_path_filter(self):
        for lane, (path, job_id, _) in LANES.items():
            with self.subTest(lane=lane):
                block = job_block(path, job_id)
                self.assertIn("    needs: changes\n", block)
                self.assertIn("!cancelled()", job_condition(path, job_id))

    def test_classification_job_names_do_not_collide_with_required_contexts(self):
        names = []
        for path in sorted(WORKFLOWS.glob("*.yml")):
            names += re.findall(r"(?m)^    name: (.+)$", path.read_text(encoding="utf-8"))
        # Required contexts are keyed by job name, so a duplicate name would let
        # one workflow's result stand in for another's.
        self.assertEqual([n for n in names if names.count(n) > 1], [])
        for path, job_id in ((IOS, "changes"), (LAB_CLI, "changes")):
            with self.subTest(workflow=path.name):
                self.assertNotEqual(job_name(path, job_id), job_name(PR_CI, "changes"))

    def test_classification_jobs_run_only_for_pull_requests_with_the_shared_classifier(self):
        for path in (IOS, LAB_CLI):
            with self.subTest(workflow=path.name):
                block = job_block(path, "changes")
                self.assertIn("if: ${{ github.event_name == 'pull_request' }}", block)
                self.assertIn("python3 scripts/ci_change_filter.py --input", block)
                self.assertIn("github.rest.pulls.listFiles", block)
                self.assertIn("previous_filename", block)
                self.assertIn("persist-credentials: false", block)
                self.assertIn("ref: ${{ github.event.pull_request.head.sha || github.sha }}", block)
                self.assertNotIn("secrets.", block)


class DocsOnlyPullRequestTest(unittest.TestCase):
    def test_docs_only_pr_skips_both_lanes(self):
        for files in (DOCS_ONLY, ["README.md", "android/README.md"], ["docs/a.md", "docs/img/x.png"]):
            for lane in LANES:
                with self.subTest(lane=lane, files=files):
                    self.assertFalse(lane_runs(lane, files=files))

    def test_classifier_output_for_a_docs_only_pr_reaches_the_condition(self):
        # Through the real script and a JSON file, as the workflow runs it.
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "files.json"
            source.write_text(json.dumps({"files": DOCS_ONLY}), encoding="utf-8")
            result = subprocess.run(
                [sys.executable, "scripts/ci_change_filter.py", "--input", str(source)],
                cwd=ROOT, capture_output=True, text=True, check=True,
            )
        outputs = dict(line.split("=", 1) for line in result.stdout.splitlines())
        self.assertEqual(outputs["error"], "false")
        for lane in LANES:
            with self.subTest(lane=lane):
                self.assertFalse(lane_runs(lane, outputs=outputs))


class NonDocumentationPullRequestTest(unittest.TestCase):
    def test_ios_lane_runs_for_android_ios_shared_workflow_and_unknown_changes(self):
        for files in (ANDROID_ONLY, IOS_ONLY, SHARED, WORKFLOW_EDIT, UNKNOWN, DOCS_ONLY + ANDROID_ONLY):
            with self.subTest(files=files):
                self.assertTrue(lane_runs("ios", files=files))

    def test_lab_cli_lane_runs_for_lab_cli_ios_shared_workflow_and_unknown_changes(self):
        for files in (LAB_CLI_ONLY, IOS_ONLY, SHARED, WORKFLOW_EDIT, UNKNOWN, DOCS_ONLY + LAB_CLI_ONLY):
            with self.subTest(files=files):
                self.assertTrue(lane_runs("lab-cli", files=files))

    def test_a_lane_whose_inputs_did_not_change_is_skipped(self):
        self.assertFalse(lane_runs("ios", files=LAB_CLI_ONLY))
        self.assertFalse(lane_runs("lab-cli", files=ANDROID_ONLY))

    def test_this_workflow_edit_runs_both_lanes(self):
        for lane in LANES:
            with self.subTest(lane=lane):
                self.assertTrue(lane_runs(lane, files=WORKFLOW_EDIT))


class FailClosedTest(unittest.TestCase):
    def test_failed_or_skipped_classification_runs_both_lanes_on_a_pull_request(self):
        for result in ("failure", "skipped"):
            for lane in LANES:
                with self.subTest(lane=lane, result=result):
                    # No outputs at all: the classification job produced nothing.
                    self.assertTrue(lane_runs(lane, changes_result=result, outputs={}))
                    # Even outputs that would skip must not be trusted from a failed job.
                    self.assertTrue(lane_runs(lane, changes_result=result, files=DOCS_ONLY))

    def test_classifier_input_failure_reports_error_and_runs_both_lanes(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "files.json"
            # The collection step writes this when the API call fails.
            source.write_text(json.dumps({"error": "API rate limit"}), encoding="utf-8")
            result = subprocess.run(
                [sys.executable, "scripts/ci_change_filter.py", "--input", str(source)],
                cwd=ROOT, capture_output=True, text=True, check=True,
            )
        outputs = dict(line.split("=", 1) for line in result.stdout.splitlines())
        self.assertEqual(outputs["error"], "true")
        for lane in LANES:
            with self.subTest(lane=lane):
                self.assertTrue(lane_runs(lane, outputs=outputs))

    def test_empty_file_list_runs_both_lanes(self):
        for lane in LANES:
            with self.subTest(lane=lane):
                self.assertTrue(lane_runs(lane, files=[]))

    def test_a_cancelled_run_does_not_start_either_lane(self):
        for lane, (path, job_id, _) in LANES.items():
            with self.subTest(lane=lane):
                self.assertFalse(evaluate(
                    job_condition(path, job_id), event="pull_request",
                    changes_result="cancelled", outputs={}, cancelled=True,
                ))


class NonPullRequestEventTest(unittest.TestCase):
    def test_main_push_and_manual_dispatch_always_run_both_lanes(self):
        for event in ("push", "workflow_dispatch"):
            for lane in LANES:
                # The classification job is skipped off pull requests.
                for outputs in ({}, outputs_for(DOCS_ONLY)):
                    with self.subTest(event=event, lane=lane, outputs=outputs):
                        self.assertTrue(lane_runs(
                            lane, event=event, changes_result="skipped", outputs=outputs,
                        ))


if __name__ == "__main__":
    unittest.main()
