"""Keep the hosted iOS gate current on every PR head, including drafts."""

import unittest
from pathlib import Path

from scripts.tests.workflow_yaml import workflow_data


WORKFLOW_PATH = Path(__file__).parents[2] / ".github/workflows/pr-ci-ios-macos.yml"

EXPECTED_PATHS = [
    '.github/workflows/pr-ci-ios-macos.yml',
    'ios/**',
    'shared/**',
    'android/build.gradle.kts',
    'android/settings.gradle.kts',
    'android/gradle.properties',
    'android/gradlew',
    'android/gradle/wrapper/**',
    'android/gradle/*.toml',
    'scripts/ci_change_filter.py',
    'scripts/ios_pr_run_reuse.py',
    'scripts/xcodegen_generate_checked.sh',
    'scripts/resolve_kmp_java_home.sh',
    'scripts/download_xcodegen.sh',
    'scripts/ci_simulator.py',
    'scripts/ios_ui_smoke.py',
    'scripts/ios_ci_timing.py',
    'scripts/ios_ci_products.py',
    'scripts/ios-ui-durations.json',
    'scripts/ios-ui-iphone-skips.txt',
    'scripts/run_local_tests.py',
]


def workflow_text() -> str:
    return WORKFLOW_PATH.read_text(encoding="utf-8")


class PrCiIosMacosTriggerTest(unittest.TestCase):
    def test_pull_request_fires_on_every_head(self) -> None:
        section = workflow_data(workflow_text())["on"]["pull_request"]
        self.assertEqual(section, {"types": [
            "opened", "synchronize", "reopened", "ready_for_review", "labeled", "closed",
        ]})

    def test_drafts_also_get_exact_head_evidence(self) -> None:
        jobs = workflow_data(workflow_text())["jobs"]
        checkouts = []
        for job in jobs.values():
            self.assertNotIn("pull_request.draft", job.get("if", ""))
            for step in job.get("steps", []):
                self.assertNotIn("pull_request.draft", step.get("if", ""))
                if step.get("uses", "").startswith("actions/checkout@"):
                    checkouts.append(step)
                    self.assertEqual(step["with"]["ref"],
                                     "${{ github.event.pull_request.head.sha || github.sha }}")
        self.assertTrue(checkouts)

    def test_push_is_limited_to_main(self) -> None:
        section = workflow_data(workflow_text())["on"]["push"]
        self.assertEqual(section["branches"], ["main"])
        self.assertNotIn("tags", section)
        self.assertNotIn("tags-ignore", section)
        self.assertNotIn("branches-ignore", section)

    def test_manual_dispatch_is_available(self) -> None:
        self.assertIn("workflow_dispatch", workflow_data(workflow_text())["on"])

    def test_main_push_keeps_the_paths_filter(self) -> None:
        self.assertEqual(workflow_data(workflow_text())["on"]["push"]["paths"], EXPECTED_PATHS)

    def test_nightly_schedule_has_no_pr_filter(self) -> None:
        events = workflow_data(workflow_text())["on"]
        self.assertEqual(events["schedule"], [{"cron": "23 3 * * *"}])
        self.assertNotIn("unlabeled", events["pull_request"]["types"])

    def test_run_name_displays_automatic_mode_for_unlabeled_prs(self) -> None:
        name = workflow_data(workflow_text())["run-name"]
        self.assertIn("github.event_name == 'pull_request'", name)
        self.assertIn("github.event.pull_request.labels.*.name", name)
        self.assertIn("ci:full-ui", name)
        self.assertIn("'auto' || 'full'", name)

    def test_concurrency_still_cancels_superseded_runs(self) -> None:
        from scripts.tests.test_merge_group_workflows import render
        data = workflow_data(workflow_text())
        concurrency = data["concurrency"]
        self.assertEqual(concurrency["cancel-in-progress"], "${{ github.event.action != 'ready_for_review' }}")
        self.assertIn("${{ github.event_name }}", concurrency["group"])
        pr = dict(event="pull_request", pr=42, ref="refs/pull/42/merge")
        active = render(concurrency["group"], **pr, action="synchronize")
        self.assertEqual(active, "pr-ios-macos-pull_request-refs/pull/42/merge")
        self.assertEqual(render(concurrency["group"], **{**pr, "ref": "refs/heads/release/1.1.0"},
                                action="closed"), active)
        self.assertEqual(render(concurrency["group"], **pr, action="labeled", label="ci:full-ui"), active)
        self.assertNotEqual(render(concurrency["group"], **pr, action="labeled", label="triage"), active)
        self.assertNotEqual(render(concurrency["group"], **pr, action="closed", attempt=2), active)
        aggregate = data["jobs"]["ios-simulator"]["name"]
        self.assertNotIn("needs.", aggregate)
        for action, label, active in (("opened", "", True), ("synchronize", "", True),
                                      ("reopened", "", True), ("ready_for_review", "", True),
                                      ("labeled", "ci:full-ui", True), ("labeled", "triage", False),
                                      ("closed", "", False), ("", "", False)):
            for result in ("skipped", "failure", "success"):
                self.assertEqual(render(aggregate, **pr, action=action, label=label, changes_result=result),
                                 "iOS simulator" if active else "iOS simulator (inactive)")

    def test_lookup_falls_back_when_older_pr_head_has_no_helper(self):
        import os
        import subprocess
        import tempfile
        step = next(s for s in workflow_data(workflow_text())["jobs"]["plan"]["steps"] if s.get("id") == "previous")
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "step-output"
            output.touch()
            subprocess.run(["bash", "-eu", "-c", step["run"]], check=True, cwd=directory,
                           env={**os.environ, "MODE": "smoke", "GITHUB_OUTPUT": str(output)})
            self.assertEqual(output.read_text(), "")

    def test_only_full_label_enters_the_pr_workflow_and_close_never_tests(self):
        from scripts.tests.test_merge_group_workflows import render
        jobs = workflow_data(workflow_text())["jobs"]
        context = dict(event="pull_request", ref="refs/pull/42/merge", pr=42, labels=[{"name": "ci:full-ui"}])
        for action, label, active in (("opened", "", True), ("ready_for_review", "", True),
                                      ("labeled", "ci:full-ui", True), ("labeled", "triage", False),
                                      ("closed", "", False)):
            with self.subTest(action=action, label=label):
                self.assertEqual(render(jobs["changes"]["if"], **context, action=action, label=label), str(active))
                result = "success" if active else "skipped"
                for name in ("plan", "ios-simulator"):
                    condition = jobs[name]["if"].replace("!cancelled()", "True").replace("always()", "True")
                    self.assertEqual(render(condition, **context, action=action, label=label, changes_result=result), str(active))


if __name__ == "__main__":
    unittest.main()
