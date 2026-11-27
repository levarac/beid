"""Required contexts must validate an isolated merge queue result."""

import re
import unittest

from scripts.tests.workflow_yaml import workflow_data
from scripts.tests.test_pr_ci_lane_skip import WORKFLOWS, job_name

NAMES = ("pr-ci.yml", "pr-ci-ios-macos.yml", "pr-ci-lab-cli.yml")


def expression_value(expression, *, event, ref, sha="a" * 40, pr=None, labels=None,
                     action="", label="", run_id=314, attempt=1, changes_result="success", matrix_context="", previous=""):
    """Evaluate the context/boolean subset used by checkout, group and run-name."""
    values = {
        "github.event_name": event,
        "github.event.action": action,
        "github.event.number": pr or "",
        "github.event.label.name": label,
        "github.run_id": run_id,
        "github.run_attempt": attempt,
        "needs.changes.result": changes_result,
        "matrix.context": matrix_context,
        "needs.plan.outputs.previous": previous,
        "github.ref": ref,
        "github.ref_name": ref.removeprefix("refs/heads/"),
        "github.sha": sha,
        "github.workflow": "PR CI",
        "github.event.pull_request.number": pr or "",
        "github.event.pull_request.head.sha": "b" * 40 if pr else "",
        "github.event.pull_request.base.sha": "c" * 40 if pr else "",
        "github.event.pull_request.labels": labels,
    }
    expression = expression.replace(
        "contains(github.event.pull_request.labels.*.name, 'ci:full-ui')",
        repr(labels is not None and any(label["name"] == "ci:full-ui" for label in labels)),
    )
    expression = re.sub(r"(?:github|needs|matrix)(?:\.[\w]+)+", lambda m: repr(values[m[0]]), expression)
    expression = expression.replace("null", "None").replace("&&", " and ").replace("||", " or ")
    expression = re.sub(r"!(?!=)", " not ", expression)
    return eval(expression.strip(), {"__builtins__": {}}, {"format": str.format})  # noqa: S307


def render(template, **context):
    return re.sub(r"\$\{\{ (.*?) \}\}", lambda m: str(expression_value(m[1], **context)), template)


def selected_context(job, **context):
    matrix = job["strategy"]["matrix"]
    exclusion, = matrix["exclude"]
    excluded = render(exclusion["context"], **context)
    selected, = [name for name in matrix["context"] if name != excluded]
    return selected


class MergeGroupWorkflowTest(unittest.TestCase):
    def test_trigger_lists_include_checks_requested_without_path_filters(self):
        for name in NAMES:
            with self.subTest(workflow=name):
                events = workflow_data((WORKFLOWS / name).read_text())["on"]
                expected = {"pull_request", "push", "merge_group"}
                if name != "pr-ci.yml":
                    expected.add("workflow_dispatch")
                if name == "pr-ci-ios-macos.yml":
                    expected.add("schedule")
                self.assertEqual(set(events), expected)
                self.assertIn("merge_group", events)
                self.assertEqual(events["merge_group"], {"types": ["checks_requested"]})

    def test_required_context_names_remain_available(self):
        for workflow, jobs in {
            "pr-ci.yml": {"changes": "Determine changed paths", "android": "Android build",
                          "lint": "SwiftLint", "sanity": "Repository sanity"},
            "pr-ci-ios-macos.yml": {"ios-simulator": "iOS simulator"},
            "pr-ci-lab-cli.yml": {"lab-cli": "beid-lab-cli build and test"},
        }.items():
            for job, expected in jobs.items():
                with self.subTest(workflow=workflow, job=job):
                    context = dict(event="merge_group", ref="refs/heads/queue")
                    path = WORKFLOWS / workflow
                    if job == "ios-simulator":
                        context["matrix_context"] = selected_context(workflow_data(path.read_text())["jobs"][job], **context)
                    self.assertEqual(render(job_name(path, job), **context), expected)

    def test_concurrency_separates_events_and_queue_entries(self):
        for name in NAMES:
            with self.subTest(workflow=name):
                text = (WORKFLOWS / name).read_text()
                group = re.search(r"(?m)^  group: (.+)$", text)[1]
                # The event namespace also isolates a dispatch of a queue ref.
                self.assertIn("${{ github.event_name }}", group)
                contexts = [
                    {"event": "push", "ref": "refs/heads/main"},
                    {"event": "schedule", "ref": "refs/heads/main"},
                    {"event": "pull_request", "ref": "refs/pull/42/merge", "pr": 42},
                    {"event": "merge_group", "ref": "refs/heads/gh-readonly-queue/main/pr-42-aaaa"},
                    {"event": "merge_group", "ref": "refs/heads/gh-readonly-queue/main/pr-43-bbbb"},
                    {"event": "workflow_dispatch", "ref": "refs/heads/gh-readonly-queue/main/pr-42-aaaa"},
                ]
                groups = [render(group, **context) for context in contexts]
                self.assertEqual(len(set(groups)), len(contexts))
                if name == "pr-ci-ios-macos.yml":
                    cancel = workflow_data(text)["concurrency"]["cancel-in-progress"]
                    self.assertEqual(render(cancel, event="pull_request", ref="pr", action="ready_for_review"), "False")
                    self.assertEqual(render(cancel, event="pull_request", ref="pr", action="synchronize"), "True")
                else:
                    self.assertIn("  cancel-in-progress: true\n", text)

    def test_checkout_uses_merge_group_sha_and_retains_pr_head(self):
        for name in NAMES:
            text = (WORKFLOWS / name).read_text()
            for job_id, job in workflow_data(text)["jobs"].items():
                for step in (s for s in job["steps"] if s.get("uses", "").startswith("actions/checkout@")):
                    ref = step["with"]["ref"]
                    self.assertEqual(render(ref, event="merge_group", ref="refs/heads/gh-readonly-queue/main/pr-42-aaaa"), "a" * 40)
                    pr = dict(event="pull_request", ref="refs/pull/42/merge", pr=42)
                    trusted = name == "pr-ci-ios-macos.yml" and job_id in ("changes", "plan")
                    self.assertEqual(render(ref, **pr), ("c" if trusted else "b") * 40)
                    if job_id == "ios-simulator":
                        self.assertEqual(render(ref, **pr, previous="validated receipt"), "c" * 40)

    def test_ios_run_name_displays_full_for_queue_and_labelled_prs(self):
        text = (WORKFLOWS / "pr-ci-ios-macos.yml").read_text()
        template = re.search(r'(?m)^run-name: "(.+)"$', text)[1]
        for event, labels, expected in (
            ("merge_group", None, "full"),
            ("merge_group", [], "full"),
            ("pull_request", [], "auto"),
            ("pull_request", [{"name": "ci:full-ui"}], "full"),
            ("schedule", None, "full"),
        ):
            with self.subTest(event=event, labels=labels):
                name = render(template, event=event, ref="refs/heads/main", labels=labels)
                self.assertIn(f"iOS simulator ({expected})", name)
                self.assertIn(event, name)
