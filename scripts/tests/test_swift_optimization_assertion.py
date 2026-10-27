"""The hosted build's optimization assertion must reject complete wrong values."""

import re
import unittest
from unittest.mock import patch

from scripts.tests import test_pr_ci_ios_macos_workflow as workflow


class SwiftOptimizationAssertionTests(unittest.TestCase):
    def test_wrong_optimization_values_fail_the_existing_assertion(self):
        original = workflow.workflow_text()
        self.assertIn("SWIFT_OPTIMIZATION_LEVEL=-O", original)
        token = "SWIFT_OPTIMIZATION_LEVEL=-O"
        for site in re.finditer(re.escape(token), original):
            for value in ("-Onone", "-Osize", "-Ounchecked", "-Oextra"):
                with self.subTest(site=site.start(), value=value):
                    changed = (original[:site.start()] + f"SWIFT_OPTIMIZATION_LEVEL={value}"
                               + original[site.end():])
                    result = unittest.TestResult()
                    with patch.object(workflow, "workflow_text", return_value=changed):
                        workflow.PrCiIosMacosWorkflowTest(
                            "test_debug_build_and_test_use_measured_optimization").run(result)
                    self.assertFalse(result.errors, result.errors)
                    self.assertEqual(len(result.failures), 1, "wrong value escaped the assertion")

    def test_comment_cannot_supply_the_optimization_option(self):
        original = workflow.workflow_text()
        changed = original.replace("SWIFT_OPTIMIZATION_LEVEL=-O", "OTHER_SETTING=-O", 1)
        changed = changed.replace("            OTHER_SETTING=-O", "            # SWIFT_OPTIMIZATION_LEVEL=-O\n            OTHER_SETTING=-O")
        result = unittest.TestResult()
        with patch.object(workflow, "workflow_text", return_value=changed):
            workflow.PrCiIosMacosWorkflowTest(
                "test_debug_build_and_test_use_measured_optimization").run(result)
        self.assertFalse(result.errors, result.errors)
        self.assertEqual(len(result.failures), 1)
