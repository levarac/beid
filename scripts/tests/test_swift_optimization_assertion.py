"""The optimization contract must compare full shell option values."""

import copy
import shlex
import unittest
from unittest.mock import patch

import yaml

from scripts.tests import test_pr_ci_ios_macos_workflow as workflow


class SwiftOptimizationAssertionTests(unittest.TestCase):
    def test_mutation_suite_accepts_quoted_source_values(self):
        original = workflow.workflow_text()
        for quote in ('"', "'"):
            changed = original.replace("SWIFT_OPTIMIZATION_LEVEL=-O",
                                       f"SWIFT_OPTIMIZATION_LEVEL={quote}-O{quote}")
            with self.subTest(quote=quote), patch.object(workflow, "workflow_text", return_value=changed):
                result = unittest.TestResult()
                for name in ("test_each_wrong_complete_value_fails", "test_shell_comment_cannot_supply_the_option"):
                    SwiftOptimizationAssertionTests(name).run(result)
                self.assertTrue(result.wasSuccessful(), result.failures + result.errors)

    def check_contract(self, text, expected):
        result = unittest.TestResult()
        with patch.object(workflow, "workflow_text", return_value=text):
            workflow.PrCiIosMacosWorkflowTest(
                "test_debug_build_and_test_use_measured_optimization").run(result)
        self.assertFalse(result.errors, result.errors)
        self.assertEqual(result.wasSuccessful(), expected, "wrong optimization acceptance")

    def test_each_wrong_complete_value_fails(self):
        data = workflow.workflow_data(workflow.workflow_text())
        for name in ("Build for testing", "Test without rebuilding"):
            block = workflow.named_step(data, "build", name)["run"]
            lexer = shlex.shlex(block, posix=True, punctuation_chars="();|&")
            lexer.whitespace_split = True
            tokens = list(lexer)
            sites = [index for index, token in enumerate(tokens)
                     if token.startswith("SWIFT_OPTIMIZATION_LEVEL=")]
            self.assertEqual(len(sites), 1,
                             f"build/{name}: expected one SWIFT_OPTIMIZATION_LEVEL mutation site")
            site = sites[0]
            for replacement in ("SWIFT_OPTIMIZATION_LEVEL=-Onone",
                                "SWIFT_OPTIMIZATION_LEVEL=-Osize",
                                "SWIFT_OPTIMIZATION_LEVEL=-Ounchecked",
                                "SWIFT_OPTIMIZATION_LEVEL=-Oextra",
                                "OTHER_SETTING=-O",
                                "SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_OPTIMIZATION_LEVEL=-Onone"):
                with self.subTest(step=name, replacement=replacement):
                    changed = copy.deepcopy(data)
                    # This synthetic scalar is inspected, never executed. Preserve
                    # parsed token values, including quoted source options.
                    mutated = tokens[:site] + shlex.split(replacement) + tokens[site + 1:]
                    workflow.named_step(changed, "build", name)["run"] = shlex.join(mutated)
                    self.check_contract(yaml.dump(changed), False)

    def test_shell_comment_cannot_supply_the_option(self):
        data = workflow.workflow_data(workflow.workflow_text())
        step = workflow.named_step(data, "build", "Build for testing")
        lexer = shlex.shlex(step["run"], posix=True, punctuation_chars="();|&")
        lexer.whitespace_split = True
        tokens = list(lexer)
        sites = [index for index, token in enumerate(tokens)
                 if token.startswith("SWIFT_OPTIMIZATION_LEVEL=")]
        self.assertEqual(len(sites), 1,
                         "build/Build for testing: expected one SWIFT_OPTIMIZATION_LEVEL mutation site")
        tokens[sites[0]] = "OTHER_SETTING=-O"
        # A comment in the run scalar remains a shell comment after YAML parsing.
        step["run"] = "# SWIFT_OPTIMIZATION_LEVEL=-O\n" + shlex.join(tokens)
        self.check_contract(yaml.dump(data), False)

    def test_quoted_equivalent_options_pass(self):
        original = workflow.workflow_text()
        for quote in ('"', "'"):
            with self.subTest(quote=quote):
                changed = original.replace("SWIFT_OPTIMIZATION_LEVEL=-O",
                                           f"SWIFT_OPTIMIZATION_LEVEL={quote}-O{quote}")
                self.check_contract(changed, True)
