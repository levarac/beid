"""The optimization contract must compare full shell option values."""

import re
import unittest
from unittest.mock import patch

from scripts.tests import test_pr_ci_ios_macos_workflow as workflow


class SwiftOptimizationAssertionTests(unittest.TestCase):
    def check_contract(self, text, expected):
        result = unittest.TestResult()
        with patch.object(workflow, "workflow_text", return_value=text):
            workflow.PrCiIosMacosWorkflowTest(
                "test_debug_build_and_test_use_measured_optimization").run(result)
        self.assertFalse(result.errors, result.errors)
        self.assertEqual(result.wasSuccessful(), expected, "wrong optimization acceptance")

    def test_each_wrong_complete_value_fails(self):
        original = workflow.workflow_text()
        token = "SWIFT_OPTIMIZATION_LEVEL=-O"
        sites = list(re.finditer(re.escape(token), original))
        self.assertEqual(len(sites), 2)
        for site in sites:
            for replacement in ("SWIFT_OPTIMIZATION_LEVEL=-Onone",
                                "SWIFT_OPTIMIZATION_LEVEL=-Osize",
                                "SWIFT_OPTIMIZATION_LEVEL=-Ounchecked",
                                "SWIFT_OPTIMIZATION_LEVEL=-Oextra",
                                "OTHER_SETTING=-O",
                                "SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_OPTIMIZATION_LEVEL=-Onone"):
                with self.subTest(site=site.start(), replacement=replacement):
                    self.check_contract(original[:site.start()] + replacement + original[site.end():], False)

    def test_shell_comment_cannot_supply_the_option(self):
        original = workflow.workflow_text()
        changed = original.replace("SWIFT_OPTIMIZATION_LEVEL=-O", "OTHER_SETTING=-O", 1)
        # A comment in the run scalar remains a shell comment after YAML parsing.
        changed = changed.replace("          set -euo pipefail\n",
                                  "          # SWIFT_OPTIMIZATION_LEVEL=-O\n          set -euo pipefail\n")
        self.check_contract(changed, False)

    def test_quoted_equivalent_options_pass(self):
        original = workflow.workflow_text()
        for quote in ('"', "'"):
            with self.subTest(quote=quote):
                changed = original.replace("SWIFT_OPTIMIZATION_LEVEL=-O",
                                           f"SWIFT_OPTIMIZATION_LEVEL={quote}-O{quote}")
                self.check_contract(changed, True)
