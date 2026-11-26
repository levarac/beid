"""Pin the hosted graph, bounded concurrency, and artifact-only test jobs."""

import re
import unittest

from scripts.tests.test_pr_ci_lane_skip import IOS, job_block


class ShardWorkflowTest(unittest.TestCase):
    def test_full_build_precedes_one_wave_of_test_jobs(self):
        text = IOS.read_text()
        self.assertIn("  tests:\n", text, "missing full-mode matrix")
        build, tests = job_block(IOS, "build"), job_block(IOS, "tests")
        self.assertIn("needs: [plan, build]", tests)
        self.assertIn("needs.plan.outputs.mode == 'full'", tests)
        self.assertIn("max-parallel: 6", tests)
        self.assertIn("fail-fast: false", tests)
        self.assertIn("fromJSON(needs.plan.outputs.matrix)", tests)
        self.assertEqual(text.count("    runs-on: xcode-27\n"), 2)
        for job in (build, tests):
            self.assertIn("runs-on: xcode-27", job)
            self.assertIn('= "Xcode 27.2"', job)
        self.assertIn('item.get("name") == "iOS 27.0"', build)
        self.assertIn("IOS_UI_SHARDS: '5'", text)
        self.assertIn("build-for-testing", build)
        self.assertNotIn("build-for-testing", tests)

    def test_selected_plan_drives_build_matrix_and_aggregate(self):
        from scripts.tests.workflow_yaml import workflow_data
        jobs = workflow_data(IOS.read_text())["jobs"]
        planner = jobs["plan"]
        for output in ("mode", "matrix", "proposal"):
            self.assertEqual(planner["outputs"][output], "${{ steps.plan.outputs." + output + " }}")
        select = next(step for step in planner["steps"] if step.get("id") == "plan")
        self.assertIn("scripts.ios_ui_pr_plan", select["run"])
        self.assertEqual(select["env"]["INITIAL_MODE"], "${{ steps.test-mode.outputs.mode }}")
        upload = next(step for step in planner["steps"] if "upload-artifact@" in step.get("uses", ""))
        self.assertIn("steps.plan.outputs.mode == 'selected'", upload["if"])
        self.assertEqual(upload["with"]["name"], "ios-ui-selection-${{ github.run_attempt }}")
        self.assertIn("needs.plan.outputs.mode == 'selected'", jobs["tests"]["if"])
        for name in ("Package full-mode test products", "Upload full-mode test products"):
            step = next(step for step in jobs["build"]["steps"] if step.get("name") == name)
            self.assertIn("needs.plan.outputs.mode == 'selected'", step["if"])
        enumerate_step = next(step for step in jobs["build"]["steps"] if step.get("id") == "enumerate")
        self.assertEqual(enumerate_step["env"]["PROPOSAL"], "${{ needs.plan.outputs.proposal }}")
        self.assertIn('--proposal "$RUNNER_TEMP/ui-selection.json"', enumerate_step["run"])

    def test_release_kmp_is_scoped_to_the_debug_test_build(self):
        build = job_block(IOS, "build")
        build_step = build.split("      - name: Build for testing\n", 1)[1].split("      - name:", 1)[0]
        self.assertRegex(
            build_step,
            r"(?s)-configuration Debug.*SWIFT_OPTIMIZATION_LEVEL=-O.*BEID_KMP_BUILD_TYPE=Release.*build-for-testing",
        )
        self.assertEqual(IOS.read_text().count("BEID_KMP_BUILD_TYPE"), 1)

    def test_aggregate_is_always_created_with_exact_required_name(self):
        text = IOS.read_text()
        aggregate = job_block(IOS, "ios-simulator")
        self.assertIn("    if: ${{ always() }}", aggregate)
        self.assertIn("    name: iOS simulator\n", aggregate)
        self.assertIn("needs: [changes, plan, build, tests]", aggregate)
        self.assertIn("runs-on: ubuntu-24.04-arm", aggregate)
        self.assertIn("toJSON(needs)", aggregate)
        self.assertIn("pattern: ios-evidence-*\n", aggregate)
        self.assertIn("merge-multiple: false", aggregate)
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
        package = build.split("      - name: Package full-mode test products\n", 1)[1].split("      - name:", 1)[0]
        upload = build.split("      - name: Upload full-mode test products\n", 1)[1].split("      - name:", 1)[0]
        download = tests.split("      - name: Download full-mode test products\n", 1)[1].split("      - name:", 1)[0]
        self.assertIn("scripts.ios_ci_products pack", package)
        # A shard retry can have a different run attempt from the build it needs.
        self.assertIn("name: ${{ needs.build.outputs.products_artifact_name }}", download)
        self.assertIn("id: package", package)
        self.assertIn('artifact_name=ios-products-%s\\n\' "$GITHUB_RUN_ATTEMPT" >> "$GITHUB_OUTPUT"', package)
        self.assertIn("products_artifact_name: ${{ steps.package.outputs.artifact_name }}", build)
        self.assertIn("evidence_attempt: ${{ steps.initialize.outputs.attempt }}", build)
        self.assertIn("name: ${{ steps.package.outputs.artifact_name }}", upload)
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
