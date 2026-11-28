"""Pin the hosted graph, bounded concurrency, and artifact-only test jobs."""

import json
import os
import subprocess
import tempfile
import unittest

from scripts.tests.test_merge_group_workflows import render
from scripts.tests.test_pr_ci_lane_skip import IOS, ROOT, job_block
from scripts.tests.workflow_yaml import named_step, workflow_data


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
        workflow = workflow_data(text)
        self.assertEqual(workflow["env"]["IOS_UI_SHARDS"], "${{ inputs.ui_shards || '4' }}")
        sizes = workflow["on"]["workflow_dispatch"]["inputs"]["ui_shards"]
        self.assertEqual(sizes["type"], "choice")
        self.assertEqual(sizes["options"][0], "4")
        self.assertEqual(set(sizes["options"]), {"4", "5"})
        self.assertIn("os.environ['IOS_UI_SHARDS']", job_block(IOS, "plan"))
        self.assertIn('--count "$IOS_UI_SHARDS"', build)
        self.assertIn("build-for-testing", build)
        self.assertNotIn("build-for-testing", tests)

    def test_manual_matrix_rejects_two_and_three_and_accepts_four_and_five(self):
        plan = named_step(workflow_data(IOS.read_text()), "plan", "Plan bounded test matrix")
        for count in (2, 3, 4, 5):
            with self.subTest(count=count), tempfile.NamedTemporaryFile(mode="r+") as output:
                result = subprocess.run(
                    ["bash", "-c", plan["run"]], cwd=ROOT, capture_output=True, text=True,
                    env={**os.environ, "GITHUB_OUTPUT": output.name, "IOS_UI_SHARDS": str(count),
                         "EVENT_NAME": "workflow_dispatch", "CHANGES_JSON": "{}"})
                if count < 4:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("IOS_UI_SHARDS must be 4 or 5", result.stderr)
                    self.assertEqual(output.read(), "")
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    fields = dict(line.rstrip().split("=", 1) for line in output)
                    self.assertEqual(json.loads(fields["matrix"])["lane"],
                                     ["unit"] + [f"ui-{i + 1}" for i in range(count)])

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
        self.assertIn("          - iOS simulator\n", aggregate)
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

    def test_build_steps_leave_time_for_evidence_and_cleanup(self):
        workflow = workflow_data(IOS.read_text())
        limits = [int(named_step(workflow, "build", name)["timeout-minutes"])
                  for name in ("Build for testing", "Test without rebuilding")]
        self.assertGreater(min(limits), 0)
        self.assertLessEqual(sum(limits), int(workflow["jobs"]["build"]["timeout-minutes"]) - 5)

    def test_full_mode_execute_timeout_for_each_lane(self):
        workflow = workflow_data(IOS.read_text())
        self.assertEqual(int(workflow["jobs"]["tests"]["timeout-minutes"]), 55)
        step = named_step(workflow, "tests", "Execute full-mode test lane")
        default = {"unit": 40, "ui-1": 45, "ui-2": 45, "ui-3": 45, "ui-4": 45}
        for event, ref, lanes in (
            ("pull_request", "refs/pull/42/merge", default),
            ("workflow_dispatch", "refs/heads/release/1.1.0", {**default, "ui-5": 45}),
        ):
            for lane, expected in lanes.items():
                with self.subTest(event=event, lane=lane):
                    limit = render(step["timeout-minutes"], event=event, ref=ref, bindings={"matrix.lane": lane})
                    self.assertEqual(int(limit), expected)

    def test_dependency_caches_have_exact_toolchain_and_lockfile_keys(self):
        build = job_block(IOS, "build")
        self.assertIn("name: Cache KMP dependencies", build, "missing dependency cache")
        for token in ("~/.gradle/caches/modules-2/files-2.1", "~/.gradle/wrapper", "~/.konan/dependencies",
                      "android/gradle/*.toml", "android/gradle/wrapper/gradle-wrapper.properties",
                      "android/build.gradle.kts", "steps.toolchain.outputs.xcode",
                      "steps.toolchain.outputs.sdk", "steps.toolchain.outputs.jdk",
                      "runner.arch", "Package.resolved", "env.SPM_SOURCE_ROOT }}/checkouts",
                      "env.SPM_SOURCE_ROOT }}/repositories", "beid-ios-kmp-v2-"):
            self.assertIn(token, build)
        self.assertNotIn("restore-keys:", build)
        # Test jobs consume same-run artifacts and have no cache at all.
        self.assertNotIn("actions/cache@", job_block(IOS, "tests"))
