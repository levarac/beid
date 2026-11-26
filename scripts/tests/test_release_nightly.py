import json
from pathlib import Path
import unittest
from unittest.mock import Mock, patch

from scripts import release_nightly as nightly

A, B = "a" * 40, "b" * 40
ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/release-ios-nightly.yml"


class NightlyPlanTests(unittest.TestCase):
    def test_resolve_once_and_keep_that_commit_after_branch_moves(self):
        api = Mock()
        api.read.side_effect = [
            json.dumps(
                {"ref": f"refs/heads/{nightly.BRANCH}", "object": {"type": "commit", "sha": sha}}
            )
            for sha in (A, B)
        ]
        head = nightly.pin(api, 100, 1)
        with (
            patch.object(nightly, "previous", return_value=B),
            patch.object(nightly, "exact_pass", return_value=None) as lookup,
        ):
            self.assertTrue(nightly.decide(api, head, 100, None)[0])
            lookup.assert_called_once_with(api, A, None)
        self.assertEqual(api.read.call_count, 1)

    def test_unchanged_observation_skips_even_after_a_failed_night(self):
        api = Mock()
        api.runs.return_value = [
            {"id": 11, "run_number": 11},
            {"id": 9, "run_number": 10, "conclusion": "failure"},
        ]
        api.artifacts.return_value = {"release-observation-1": {"id": 10}}
        api.files.return_value = {
            "observation.json": {"branch": nightly.BRANCH, "sha": A, "run_id": 9, "attempt": 1}
        }
        with patch.object(nightly, "exact_pass") as lookup:
            self.assertFalse(nightly.decide(api, A, 11, None)[0])
            lookup.assert_not_called()

    def test_first_scheduled_run_executes_unless_exact_full_already_passed(self):
        for proof, expected in [(None, True), (41, False)]:
            api = Mock()
            with self.subTest(proof=proof), patch.object(nightly, "exact_pass", return_value=proof):
                run, reason = nightly.decide(api, A, 1, None)
                self.assertEqual(run, expected)
                self.assertIn("first" if expected else "verified full", reason)
                api.runs.assert_not_called()

    def test_known_previous_run_with_missing_expired_or_unreadable_receipt_skips(self):
        for result, diagnostic in [(None, "missing or expired"), (OSError(), "unreadable")]:
            with self.subTest(diagnostic=diagnostic):
                api = Mock()
                api.runs.return_value = [{"id": 7, "run_number": 4}]
                with (
                    patch.object(nightly, "observation", return_value=None, side_effect=result),
                    patch.object(nightly, "exact_pass") as lookup,
                ):
                    run, reason = nightly.decide(api, A, 5, None)
                    self.assertFalse(run)
                    self.assertIn(diagnostic, reason)
                    lookup.assert_not_called()

    def test_deleted_previous_run_or_same_run_retry_cannot_establish_a_change(self):
        api = Mock()
        api.runs.return_value = [{"id": 99, "run_number": 5}, {"id": 90, "run_number": 3}]
        run, reason = nightly.decide(api, A, 5, None)
        self.assertFalse(run)
        self.assertIn("absent", reason)
        api.artifacts.assert_not_called()

    def test_changed_release_runs_when_full_evidence_is_unreadable(self):
        with (
            patch.object(nightly, "previous", return_value=B),
            patch.object(nightly, "exact_pass", side_effect=OSError()),
        ):
            run, reason = nightly.decide(Mock(), A, 5, None)
            self.assertTrue(run)
            self.assertIn("full-pass evidence unavailable", reason)

    def test_changed_head_skips_only_on_verified_full_proof(self):
        with (
            patch.object(nightly, "previous", return_value=B),
            patch.object(nightly, "exact_pass", return_value=41),
        ):
            self.assertEqual(
                nightly.decide(Mock(), A, 100, None), (False, "verified full pass in run 41")
            )

    def test_retry_reuses_its_record_or_fails_before_resolving(self):
        api = Mock()
        with patch.object(nightly, "observation", return_value=B):
            self.assertEqual(nightly.pin(api, 99, 2), B)
        with patch.object(nightly, "observation", return_value=None), self.assertRaises(ValueError):
            nightly.pin(api, 99, 2)
        api.read.assert_not_called()


class ExistingEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.sha = A
        self.suite = Mock()
        self.u, self.a, self.b = "BeidTests/T/testU", "BeidUITests/T/testA", "BeidUITests/T/testB"
        self.manifest = dict(
            sha=A,
            mode="full",
            unit=[self.u],
            ui=[self.a, self.b],
            unit_skips=[],
            iphone_skips=[],
            shards=[[self.a], [self.b]],
        )
        self.enumeration = {"BeidTests": [self.u], "BeidUITests": [self.a, self.b]}
        self.suite.parse_enumeration.side_effect = lambda x: x
        self.suite.unique_tests.side_effect = lambda values, bundle: sorted(values)
        self.suite.parse_smoke_list.return_value = []
        self.suite.UNIT_SKIPS.read_text.return_value = ""
        self.suite.ui_shard_lanes.return_value = {"ui-1": [self.a], "ui-2": [self.b]}
        self.suite.validate_lane.side_effect = self.validate
        self.run = dict(id=14, run_attempt=1, status="completed", conclusion="success", head_sha=A)
        prefix = "ios-evidence-1-"
        self.artifacts = {
            prefix + "build": {
                "manifest.json": self.manifest,
                "enumerated-tests.json": self.enumeration,
            }
        }
        for lane, case in (("unit", self.u), ("ui-1", self.a), ("ui-2", self.b)):
            self.artifacts[prefix + lane] = {
                "manifest.json": self.manifest,
                "test-tree.json": [case],
            }
        self.api = Mock()
        self.api.artifacts.return_value = self.artifacts
        self.api.files.side_effect = lambda data, *names: {k: data[k] for k in names}
        self.api.objects.return_value = [
            {"name": name, "conclusion": "success"}
            for name in (
                "Build iOS test bundles",
                "iOS simulator",
                "iOS full tests (unit)",
                "iOS full tests (ui-1)",
                "iOS full tests (ui-2)",
            )
        ]

    @staticmethod
    def validate(expected, tree, skips):
        if sorted(expected) != sorted(tree):
            raise ValueError("case mismatch")
        return [(case, "Passed", 1.0) for case in tree]

    def test_exact_full_requires_all_lanes_enumeration_and_trees(self):
        self.assertTrue(nightly.passed_pr(self.api, self.run, A, self.suite))
        self.artifacts["ios-evidence-1-ui-1"]["test-tree.json"] = []
        with self.assertRaises(ValueError):
            nightly.passed_pr(self.api, self.run, A, self.suite)

    def test_smoke_noop_failed_cancelled_and_other_sha_are_ineligible(self):
        for patch_data in [
            dict(conclusion="failure"),
            dict(conclusion="cancelled"),
            dict(head_sha=B),
            dict(status="in_progress"),
        ]:
            self.assertFalse(nightly.passed_pr(self.api, self.run | patch_data, A, self.suite))
        self.manifest["mode"] = "smoke"
        with self.assertRaises(ValueError):
            nightly.passed_pr(self.api, self.run, A, self.suite)
        self.manifest["mode"] = "full"
        self.api.objects.return_value = [{"name": "iOS simulator", "conclusion": "success"}]
        self.assertFalse(nightly.passed_pr(self.api, self.run, A, self.suite))

    def test_serial_execution_cannot_verify_missing_or_duplicate_cases(self):
        for tree in ([self.u, self.a], [self.u, self.a, self.a, self.b]):
            with self.assertRaises(ValueError):
                nightly.verify_single(self.manifest, self.enumeration, tree, A, self.suite)
        self.assertEqual(
            nightly.verify_single(
                self.manifest, self.enumeration, [self.u, self.a, self.b], A, self.suite
            )["passed"],
            3,
        )

    def test_wrong_tested_sha_or_omitted_compiled_test_cannot_verify(self):
        with self.assertRaises(ValueError):
            nightly.verify_single(
                self.manifest, self.enumeration, [self.u, self.a, self.b], B, self.suite
            )
        with self.assertRaises(ValueError):
            nightly.verify_single(
                self.manifest,
                {"BeidTests": [], "BeidUITests": [self.a, self.b]},
                [self.u, self.a, self.b],
                A,
                self.suite,
            )

    def test_schedule_pins_source_and_publishes_only_after_verified_success(self):
        text = WORKFLOW.read_text()
        self.assertIn("cron: '23 17 * * *'", text)
        self.assertIn("group: release-ios-nightly", text)
        self.assertIn("ref: ${{ steps.observe.outputs.sha }}", text)
        self.assertIn("ref: ${{ needs.plan.outputs.sha }}", text)
        self.assertIn("RELEASE_SHA: ${{ needs.plan.outputs.sha }}", text)
        self.assertIn('test "$(git rev-parse HEAD)" = "$RELEASE_SHA"', text)
        self.assertIn("name: release-full-${{ needs.plan.outputs.sha }}", text)
        self.assertIn("if: success() && steps.verify.outputs.verified == 'true'", text)
        self.assertIn("if: needs.plan.outputs.run == 'true'", text)
        self.assertNotIn(": write", text)
        self.assertEqual(
            text.count("persist-credentials: false"), text.count("uses: actions/checkout@")
        )
