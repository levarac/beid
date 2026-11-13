"""Pin the hosted graph, bounded concurrency, and artifact-only test jobs."""

import json
import re
import subprocess
import sys
import textwrap
import unittest

from scripts.tests.test_pr_ci_lane_skip import IOS, job_block


class ShardWorkflowTest(unittest.TestCase):
    def test_full_build_precedes_five_test_jobs_with_four_concurrent(self):
        text = IOS.read_text()
        self.assertIn("  tests:\n", text, "missing full-mode matrix")
        build, tests = job_block(IOS, "build"), job_block(IOS, "tests")
        self.assertIn("needs: [plan, build]", tests)
        self.assertIn("needs.plan.outputs.mode == 'full'", tests)
        self.assertIn("max-parallel: 4", tests)
        self.assertIn("fail-fast: false", tests)
        self.assertIn("fromJSON(needs.plan.outputs.matrix)", tests)
        self.assertEqual(text.count("    runs-on: macos-26\n"), 2)
        self.assertIn("IOS_UI_SHARDS: '4'", text)
        self.assertIn("build-for-testing", build)
        self.assertNotIn("build-for-testing", tests)

    def test_planner_accepts_only_two_three_or_four_ui_shards(self):
        plan = job_block(IOS, "plan")
        snippet = plan.split("          python3 - <<'PY' >> \"$GITHUB_OUTPUT\"\n", 1)[1].split("          PY\n", 1)[0]
        code = textwrap.dedent(snippet)
        expected_lanes = {
            "2": ["unit", "ui-1", "ui-2"],
            "3": ["unit", "ui-1", "ui-2", "ui-3"],
            "4": ["unit", "ui-1", "ui-2", "ui-3", "ui-4"],
        }
        for count in ("2", "3", "4", "0", "1", "5", "6", "true", "false", "", "4.0"):
            with self.subTest(count=count):
                result = subprocess.run([sys.executable, "-B", "-c", code], cwd=IOS.parents[2],
                    env={"IOS_UI_SHARDS": count, "EVENT_NAME": "merge_group", "CHANGES_JSON": "{}"},
                    capture_output=True, text=True)
                if count in expected_lanes:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    outputs = dict(line.split("=", 1) for line in result.stdout.splitlines())
                    self.assertEqual(outputs["run"], "true")
                    self.assertEqual(json.loads(outputs["matrix"]), {"lane": expected_lanes[count]})
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertNotIn("matrix=", result.stdout)

    def test_aggregate_is_always_created_with_exact_required_name(self):
        text = IOS.read_text()
        aggregate = job_block(IOS, "ios-simulator")
        self.assertIn("    if: ${{ always() }}", aggregate)
        self.assertIn("    name: iOS simulator\n", aggregate)
        self.assertIn("needs: [changes, plan, build, tests]", aggregate)
        self.assertIn("runs-on: ubuntu-24.04-arm", aggregate)
        self.assertIn("toJSON(needs)", aggregate)
        self.assertIn("scripts.ios_ui_smoke aggregate", aggregate)
        self.assertNotIn("continue-on-error", text)

    def test_test_jobs_use_transferred_run_file_and_owned_state(self):
        text = IOS.read_text()
        self.assertIn("  tests:\n", text, "missing full-mode matrix")
        tests = job_block(IOS, "tests")
        for token in ("scripts.ios_ci_products unpack", "-xctestrun", "-derivedDataPath",
                      "-resultBundlePath", "scripts/ci_simulator.py", "simctl delete",
                      "-parallel-testing-enabled NO", "-maximum-concurrent-test-simulator-destinations 1"):
            self.assertIn(token, tests)
        self.assertNotIn("-project", tests)
        self.assertNotIn("-scheme", tests)
        self.assertIn("${{ matrix.lane }}", tests)

    def test_products_and_result_artifacts_are_separate_and_attempt_scoped(self):
        text = IOS.read_text()
        self.assertIn("  build:\n", text, "missing build job")
        build, tests = job_block(IOS, "build"), job_block(IOS, "tests")
        self.assertIn("scripts.ios_ci_products pack", build)
        self.assertIn("ios-products-${{ github.run_attempt }}", build)
        self.assertIn("ios-products-${{ github.run_attempt }}", tests)
        for block in (build, tests):
            self.assertIn("ios-evidence-${{ github.run_attempt }}-", block)
            self.assertIn("if-no-files-found: error", block)
            self.assertIn("test-*.json", block)
        self.assertIn("-enumerate-tests", build)
        self.assertIn("-test-enumeration-format json", build)
        self.assertIn("scripts.ios_ui_smoke shards", build)

    def test_smoke_tests_stay_inside_build_job(self):
        text = IOS.read_text()
        self.assertIn("  build:\n", text, "missing build job")
        build = job_block(IOS, "build")
        self.assertRegex(build, r"name: Test without rebuilding\n(?:.*\n){0,3}.*mode == 'smoke'")
        self.assertIn("--lane build", build)
        self.assertNotIn("simctl erase", text)

    def test_long_steps_leave_time_for_evidence_and_cleanup(self):
        for job, names in (("build", ("Build for testing", "Test without rebuilding")),
                           ("tests", ("Execute full-mode test lane",))):
            block = job_block(IOS, job)
            job_limit = int(re.search(r"^    timeout-minutes: (\d+)$", block, re.M)[1])
            step_limits = []
            for name in names:
                step = re.search(rf"^      - name: {re.escape(name)}\n(?:(?!      - ).*\n)*", block, re.M)[0]
                limit = re.search(r"^        timeout-minutes: (\d+)$", step, re.M)
                self.assertIsNotNone(limit, f"unbounded step: {name}")
                step_limits.append(int(limit[1]))
                self.assertGreater(step_limits[-1], 0)
            self.assertLessEqual(sum(step_limits), job_limit - 5)

    def test_dependency_caches_have_exact_toolchain_and_lockfile_keys(self):
        build = job_block(IOS, "build")
        self.assertIn("name: Cache KMP dependencies", build, "missing dependency cache")
        for token in ("~/.gradle/caches", "~/.gradle/wrapper", "~/.konan",
                      "android/gradle/*.toml", "android/gradle/wrapper/gradle-wrapper.properties",
                      "android/build.gradle.kts", "steps.toolchain.outputs.xcode",
                      "steps.toolchain.outputs.sdk", "steps.toolchain.outputs.jdk",
                      "runner.arch", "Package.resolved", "env.SPM_SOURCE_ROOT }}/checkouts",
                      "env.SPM_SOURCE_ROOT }}/repositories", "!~/.gradle/caches/build-cache-*"):
            self.assertIn(token, build)
        self.assertNotIn("restore-keys:", build)
        # Test jobs consume same-run artifacts and have no cache at all.
        self.assertNotIn("actions/cache@", job_block(IOS, "tests"))
