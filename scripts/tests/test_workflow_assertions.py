"""Exercise workflow assertions with equivalent YAML and real regressions."""

import copy
import unittest
from unittest.mock import patch

import yaml

from scripts.tests import test_pr_ci_ios_macos_workflow as release
from scripts.tests import test_pr_ci_ios_macos_triggers as triggers


def run_assertions(case_type, module, function, text):
    result = unittest.TestResult()
    with patch.object(module, function, return_value=text):
        unittest.defaultTestLoader.loadTestsFromTestCase(case_type).run(result)
    return result


def load(text):
    # Quote Actions' `on` for PyYAML's YAML 1.1 safe loader in these mutations.
    return yaml.safe_load(text.replace("\non:\n", "\n'on':\n"))


class WorkflowAssertionTests(unittest.TestCase):
    def test_equivalent_release_yaml_passes(self):
        original = release.release_workflow_text()
        variants = [
            original.replace("push:\n", "push: # main only\n")
                    .replace("branches: [main]", "branches:\n      - 'main'")
                    .replace("workflow_dispatch:\n", "workflow_dispatch: # manual\n"),
            yaml.safe_dump(load(original), sort_keys=False),
            original + "\n# needs: upload-artifact\n# runs-on: self-hosted\n",
        ]
        for text in variants:
            with self.subTest(text=text[:80]):
                result = run_assertions(release.MainIosReleaseBuildWorkflowTest, release,
                                        "release_workflow_text", text)
                self.assertTrue(result.wasSuccessful(), result.failures + result.errors)

    def test_real_release_trigger_runner_and_step_changes_fail(self):
        original = load(release.release_workflow_text())
        for change in ("branch", "dispatch", "pr", "runner", "command", "upload", "needs"):
            data = copy.deepcopy(original)
            job = data["jobs"]["ios-release-build"]
            if change == "branch":
                data["on"]["push"]["branches"] = ["other"]
            elif change == "dispatch":
                del data["on"]["workflow_dispatch"]
            elif change == "pr":
                data["on"]["pull_request"] = None
            elif change == "runner":
                job["runs-on"] = "self-hosted"
            elif change == "command":
                step = next(s for s in job["steps"] if s.get("name") == "Build Release for device")
                step["run"] = step["run"].replace("CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_ALLOWED=YES")
            elif change == "upload":
                job["steps"].append({"uses": "actions/upload-artifact@" + "a" * 40})
            else:
                job["needs"] = "another-job"
            with self.subTest(change=change):
                text = yaml.safe_dump(data, sort_keys=False) + "\n# runs-on: macos-26\n"
                result = run_assertions(release.MainIosReleaseBuildWorkflowTest, release,
                                        "release_workflow_text", text)
                self.assertFalse(result.wasSuccessful())

    def test_comment_cannot_supply_the_release_runner(self):
        text = release.release_workflow_text().replace(
            "runs-on: macos-26", "runs-on: self-hosted # runs-on: macos-26")
        result = run_assertions(release.MainIosReleaseBuildWorkflowTest, release,
                                "release_workflow_text", text)
        self.assertFalse(result.wasSuccessful())

    def test_equivalent_hosted_trigger_yaml_passes(self):
        data = load(triggers.workflow_text())
        result = run_assertions(triggers.PrCiIosMacosTriggerTest, triggers,
                                "workflow_text", yaml.safe_dump(data, sort_keys=False))
        self.assertTrue(result.wasSuccessful(), result.failures + result.errors)

    def test_real_hosted_trigger_changes_fail(self):
        original = load(triggers.workflow_text())
        for change in ("pr-types", "pr-paths", "push-branch", "schedule", "checkout"):
            data = copy.deepcopy(original)
            if change == "pr-types":
                data["on"]["pull_request"]["types"].remove("synchronize")
            elif change == "pr-paths":
                data["on"]["pull_request"]["paths"] = ["ios/**"]
            elif change == "push-branch":
                data["on"]["push"]["branches"] = ["other"]
            elif change == "schedule":
                data["on"]["schedule"][0]["cron"] = "0 0 * * *"
            else:
                for job in data["jobs"].values():
                    for step in job.get("steps", []):
                        if step.get("uses", "").startswith("actions/checkout@"):
                            step["with"]["ref"] = "main"
            result = run_assertions(triggers.PrCiIosMacosTriggerTest, triggers,
                                    "workflow_text", yaml.safe_dump(data, sort_keys=False))
            with self.subTest(change=change):
                self.assertFalse(result.wasSuccessful())
