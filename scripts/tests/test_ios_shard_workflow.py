"""Pin the hosted graph, bounded concurrency, and artifact-only test jobs."""

import re
import unittest

from scripts.tests.test_pr_ci_lane_skip import IOS, job_block


class ShardWorkflowTest(unittest.TestCase):
    def test_full_build_precedes_at_most_four_test_jobs(self):
        text = IOS.read_text()
        self.assertIn("  tests:\n", text, "missing full-mode matrix")
        build, tests = job_block(IOS, "build"), job_block(IOS, "tests")
        self.assertIn("needs: [plan, build]", tests)
        self.assertIn("needs.plan.outputs.mode == 'full'", tests)
        self.assertIn("max-parallel: 4", tests)
        self.assertIn("fail-fast: false", tests)
        self.assertIn("fromJSON(needs.plan.outputs.matrix)", tests)
        self.assertEqual(text.count("    runs-on: macos-26\n"), 2)
        self.assertIn("IOS_UI_SHARDS: '3'", text)
        self.assertIn("build-for-testing", build)
        self.assertNotIn("build-for-testing", tests)

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
