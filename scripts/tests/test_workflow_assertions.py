"""Formatting changes must pass; changes to workflow behavior must fail."""

import copy
import unittest
from unittest.mock import patch

import yaml

from scripts.tests import test_pr_ci_ios_macos_workflow as workflow
from scripts.tests import test_pr_ci_ios_macos_triggers as triggers
from scripts.tests.workflow_yaml import workflow_data


def run_assertions(case_type, module, function, text):
    result = unittest.TestResult()
    with patch.object(module, function, return_value=text):
        unittest.defaultTestLoader.loadTestsFromTestCase(case_type).run(result)
    return result


class WorkflowAssertionTests(unittest.TestCase):
    def check_variant(self, module, case, function, data, expected=True):
        text = yaml.safe_dump(data, sort_keys=False)
        result = run_assertions(case, module, function, text)
        self.assertEqual(result.wasSuccessful(), expected, result.failures + result.errors)

    def test_equivalent_yaml_passes_for_current_hosted_and_release_lanes(self):
        for module, case, function in (
            (triggers, triggers.PrCiIosMacosTriggerTest, "workflow_text"),
            (workflow, workflow.PrCiIosMacosWorkflowTest, "workflow_text"),
            (workflow, workflow.MainIosReleaseBuildWorkflowTest, "release_workflow_text"),
        ):
            with self.subTest(case=case.__name__):
                data = workflow_data(getattr(module, function)())
                self.check_variant(module, case, function, data)

    def test_hosted_trigger_changes_fail(self):
        original = workflow_data(triggers.workflow_text())
        for change in ("pr-types", "pr-paths", "pr-paths-ignore", "branch", "tags",
                       "dispatch", "schedule", "checkout", "draft", "cancel", "group"):
            data = copy.deepcopy(original)
            if change == "pr-types":
                data["on"]["pull_request"]["types"].remove("synchronize")
            elif change in ("pr-paths", "pr-paths-ignore"):
                data["on"]["pull_request"][change.removeprefix("pr-")] = ["ios/**"]
            elif change == "branch":
                data["on"]["push"]["branches"] = ["other"]
            elif change == "tags":
                data["on"]["push"]["tags"] = ["v*"]
            elif change == "dispatch":
                del data["on"]["workflow_dispatch"]
            elif change == "schedule":
                data["on"]["schedule"][0]["cron"] = "0 0 * * *"
            elif change == "checkout":
                # A single incorrect shard checkout must fail even if others are correct.
                checkout = next(s for s in data["jobs"]["tests"]["steps"]
                                if s.get("uses", "").startswith("actions/checkout@"))
                checkout["with"]["ref"] = "main"
            elif change == "draft":
                data["jobs"]["build"]["if"] = "${{ !github.event.pull_request.draft }}"
            elif change == "cancel":
                data["concurrency"]["cancel-in-progress"] = "false"
            else:
                data["concurrency"]["group"] = "one-group"
            with self.subTest(change=change):
                self.check_variant(triggers, triggers.PrCiIosMacosTriggerTest,
                                   "workflow_text", data, expected=False)

    def test_release_contract_changes_fail(self):
        original = workflow_data(workflow.release_workflow_text())
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
                self.check_variant(workflow, workflow.MainIosReleaseBuildWorkflowTest,
                                   "release_workflow_text", data, expected=False)

    def test_yaml_comments_cannot_supply_runner_or_step_metadata(self):
        text = workflow.release_workflow_text().replace(
            "runs-on: macos-26", "runs-on: self-hosted # runs-on: macos-26")
        result = run_assertions(workflow.MainIosReleaseBuildWorkflowTest, workflow,
                                "release_workflow_text", text)
        self.assertFalse(result.wasSuccessful())
        text = workflow.workflow_text().replace(
            "id: simulator", "id: other # id: simulator", 1)
        result = run_assertions(workflow.PrCiIosMacosWorkflowTest, workflow,
                                "workflow_text", text)
        self.assertFalse(result.wasSuccessful())
