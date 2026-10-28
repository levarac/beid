"""Required contexts must validate an isolated merge queue result."""

import re
import unittest

from scripts.tests.test_pr_ci_ios_macos_triggers import event_section, trigger_block
from scripts.tests.test_pr_ci_lane_skip import WORKFLOWS, job_name

NAMES = ("pr-ci.yml", "pr-ci-ios-macos.yml", "pr-ci-lab-cli.yml")


def expression_value(expression, *, event, ref, sha="a" * 40, pr=None, labels=None):
    """Evaluate the context/boolean subset used by checkout, group and run-name."""
    values = {
        "github.event_name": event,
        "github.ref": ref,
        "github.ref_name": ref.removeprefix("refs/heads/"),
        "github.sha": sha,
        "github.workflow": "PR CI",
        "github.event.pull_request.number": pr or "",
        "github.event.pull_request.head.sha": "b" * 40 if pr else "",
        "github.event.pull_request.labels": labels,
    }
    expression = expression.replace(
        "contains(github.event.pull_request.labels.*.name, 'ci:full-ui')",
        repr(labels is not None and any(label["name"] == "ci:full-ui" for label in labels)),
    )
    expression = re.sub(r"github(?:\.[\w]+)+", lambda m: repr(values[m[0]]), expression)
    expression = expression.replace("null", "None").replace("&&", " and ").replace("||", " or ")
    expression = re.sub(r"!(?!=)", " not ", expression)
    return eval(expression.strip(), {"__builtins__": {}}, {})  # noqa: S307


def render(template, **context):
    return re.sub(r"\$\{\{ (.*?) \}\}", lambda m: str(expression_value(m[1], **context)), template)


class MergeGroupWorkflowTest(unittest.TestCase):
    def test_trigger_lists_include_checks_requested_without_path_filters(self):
        for name in NAMES:
            with self.subTest(workflow=name):
                block = trigger_block((WORKFLOWS / name).read_text())
                expected = {"pull_request", "push", "merge_group"}
                if name != "pr-ci.yml":
                    expected.add("workflow_dispatch")
                if name == "pr-ci-ios-macos.yml":
                    expected.add("schedule")
                self.assertEqual(set(re.findall(r"(?m)^  ([\w]+):", block)), expected)
                # Explicit membership keeps a missing trigger an assertion failure.
                self.assertIn("  merge_group:\n", block)
                section = event_section(block, "merge_group")
                self.assertEqual(section.strip(), "types: [checks_requested]")

    def test_required_context_names_remain_available(self):
        for workflow, jobs in {
            "pr-ci.yml": {"changes": "Determine changed paths", "android": "Android build",
                          "lint": "SwiftLint", "sanity": "Repository sanity"},
            "pr-ci-ios-macos.yml": {"ios-simulator": "iOS simulator"},
            "pr-ci-lab-cli.yml": {"lab-cli": "beid-lab-cli build and test"},
        }.items():
            for job, expected in jobs.items():
                with self.subTest(workflow=workflow, job=job):
                    self.assertEqual(job_name(WORKFLOWS / workflow, job), expected)

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
                self.assertIn("  cancel-in-progress: true\n", text)

    def test_checkout_uses_merge_group_sha_and_retains_pr_head(self):
        for name in NAMES:
            text = (WORKFLOWS / name).read_text()
            for checkout in text.split("- uses: actions/checkout@")[1:]:
                block = checkout.split("\n      - ", 1)[0]
                ref = re.search(r"(?m)^          ref: (.+)$", block)[1]
                with self.subTest(workflow=name, ref=ref):
                    self.assertEqual(render(ref, event="merge_group", ref="refs/heads/gh-readonly-queue/main/pr-42-aaaa"), "a" * 40)
                    self.assertEqual(render(ref, event="pull_request", ref="refs/pull/42/merge", pr=42), "b" * 40)

    def test_ios_run_name_displays_full_for_queue_and_labelled_prs(self):
        text = (WORKFLOWS / "pr-ci-ios-macos.yml").read_text()
        template = re.search(r'(?m)^run-name: "(.+)"$', text)[1]
        for event, labels, expected in (
            ("merge_group", None, "full"),
            ("merge_group", [], "full"),
            ("pull_request", [], "smoke"),
            ("pull_request", [{"name": "ci:full-ui"}], "full"),
            ("schedule", None, "full"),
        ):
            with self.subTest(event=event, labels=labels):
                name = render(template, event=event, ref="refs/heads/main", labels=labels)
                self.assertIn(f"iOS simulator ({expected})", name)
                self.assertIn(event, name)
