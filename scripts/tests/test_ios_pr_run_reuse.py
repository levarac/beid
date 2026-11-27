import json
import unittest
from unittest import mock

from scripts import ios_pr_run_reuse as reuse
from scripts.ios_ui_smoke import validate_aggregate


class PreviousRunTests(unittest.TestCase):
    def setUp(self):
        self.base, self.old, self.new = ("a" * 40, "b" * 40, "c" * 40)
        self.repo = "levarac/beid"
        repo = {"full_name": self.repo}
        self.pr = {"number": 952, "base": {"sha": self.base, "ref": "release/1.1.0", "repo": repo},
                   "head": {"sha": self.new, "ref": "branch", "repo": repo}}
        self.event = {"number": 952, "action": "synchronize", "pull_request": self.pr}
        self.run = {"id": 80, "run_attempt": 1, "event": "pull_request", "status": "completed",
                    "updated_at": "2026-11-27T01:30:00Z",
                    "head_sha": self.old, "head_branch": "branch", "head_repository": repo, "conclusion": "success",
                    "path": ".github/workflows/pr-ci-ios-macos.yml", "pull_requests": [self.pr]}
        self.runs = [self.run]
        self.compare = {"status": "ahead", "merge_base_commit": {"sha": self.old},
                        "files": [{"filename": "docs/delivery-ci.md", "status": "modified"}]}
        self.pr_files = [{"filename": "ios/BeidUITests/ExampleTests.swift", "status": "modified"}]
        self.jobs = {}
        self.record(self.old)
        self.calls = []

    def record(self, sha, mode="smoke", base=None):
        def job(name, step):
            return {"name": name, "head_sha": sha, "run_id": 80, "conclusion": "success",
                    "steps": [{"name": step, "conclusion": "success"}]}
        marker = reuse.provenance(952, base or self.base, sha, mode)
        self.jobs[sha] = [job("Plan iOS test jobs", marker),
                          job("Build iOS test bundles", "Build for testing"),
                          job("iOS simulator", "Verify all job results and execution ledger")]
        if mode == "smoke":
            self.jobs[sha][1]["steps"].extend({"name": name, "conclusion": "success"} for name in
                                              ("Test without rebuilding", "Verify UI execution and bundle durations"))
        else:
            for lane in ("unit", "ui-1", "ui-2", "ui-3", "ui-4"):
                self.jobs[sha].append(job(f"iOS full tests ({lane})", "Execute full-mode test lane"))

    def api(self, url):
        self.calls.append(url)
        if "/runs?" in url:
            return {"workflow_runs": self.runs}
        if "/jobs?" in url:
            return {"jobs": self.jobs[self.run["head_sha"]], "total_count": len(self.jobs[self.run["head_sha"]])}
        if url.startswith(f"compare/{self.base}..."):
            return {"files": self.pr_files}
        if "compare/" in url:
            return self.compare
        self.fail(url)

    def resolve(self, mode="smoke"):
        return reuse.previous_run(self.event, mode, self.repo, 90, self.api)

    def test_docs_update_cites_the_executed_ancestor_and_attempt(self):
        self.assertEqual(self.resolve(), {"run_id": 80, "attempt": 1, "sha": self.old,
                                         "mode": "smoke", "conclusion": "success"})
        self.assertIn(f"compare/{self.old}...{self.new}", self.calls)

    def test_requires_a_safe_complete_ancestor_delta(self):
        changes = self.compare["files"]
        for update in ({"status": "diverged"}, {"merge_base_commit": {"sha": self.new}},
                       {"files": []}, {"files": changes * 300},
                       {"files": [{"filename": "shared/src/Changed.kt", "status": "added"}]},
                       {"files": [{"filename": "docs/w.md", "status": "removed"}]},
                       {"files": [{"filename": "docs/w.md", "previous_filename": "ios/A.swift", "status": "renamed"}]},
                       {"files": [{"filename": "docs/w.md"}]}):
            with self.subTest(update=list(update)), mock.patch.dict(self.compare, update):
                self.assertIsNone(self.resolve())

    def test_only_actual_current_mode_same_pr_base_and_repository_can_supply_results(self):
        for update in ({"event": "workflow_dispatch"}, {"status": "queued"}, {"conclusion": "failure"},
                       {"run_attempt": 2}, {"head_repository": {"full_name": "another/repo"}},
                       {"pull_requests": []}, {"head_branch": "elsewhere"},
                       {"pull_requests": [{**self.pr, "number": 95}]}, {"path": ".github/workflows/other.yml"}):
            with self.subTest(update=update), mock.patch.dict(self.run, update):
                self.assertIsNone(self.resolve())
        self.assertIsNone(self.resolve("full"))
        self.record(self.old, base="e" * 40)
        self.assertIsNone(self.resolve())
        self.record(self.old)
        self.jobs[self.old][1]["conclusion"] = "skipped"
        self.assertIsNone(self.resolve())

    def test_newer_failure_prevents_reusing_an_older_pass(self):
        self.runs.insert(0, {**self.run, "id": 81, "conclusion": "failure"})
        self.assertIsNone(self.resolve())

    def test_pr_edits_to_its_own_gate_prevent_cross_head_reuse(self):
        self.pr_files.append({"filename": "docs/archived.md", "previous_filename": "scripts/ios_ui_smoke.py"})
        self.assertIsNone(self.resolve())

    def test_pr_build_inputs_and_mismatched_job_owners_force_a_fresh_run(self):
        for path in ("ios/project.yml", "android/app/build.gradle.kts", "scripts/ios_ui_smoke.py", "unknown/thing"):
            with self.subTest(path=path), mock.patch.dict(self.pr_files[0], filename=path):
                self.assertIsNone(self.resolve())
        for attrs in ({"run_id": 79}, {"head_sha": self.new}):
            with self.subTest(attrs=attrs), mock.patch.dict(self.jobs[self.old][1], attrs):
                self.assertIsNone(self.resolve())

    def test_ready_same_head_keeps_a_recorded_failure_and_never_compares_itself(self):
        self.event["action"] = "ready_for_review"
        self.pr["head"]["sha"] = self.old
        self.assertEqual(self.resolve()["conclusion"], "success")
        self.run["conclusion"] = "failure"
        self.jobs[self.old][-1]["conclusion"] = "failure"
        self.assertEqual(self.resolve()["conclusion"], "failure")
        self.assertFalse(any("compare/" in url for url in self.calls))

    def test_ready_can_report_the_completed_exact_head_attempt(self):
        self.event["action"] = "ready_for_review"
        self.pr["head"]["sha"] = self.old
        self.run["run_attempt"] = 2
        self.assertEqual(self.resolve()["attempt"], 2)
        self.assertIn("actions/runs/80/attempts/2/jobs?per_page=100", self.calls)

    def test_explicit_labels_and_forks_always_use_normal_planning(self):
        self.event["action"] = "labeled"
        self.assertIsNone(self.resolve())
        self.event["action"] = "synchronize"
        self.pr["head"]["repo"] = {"full_name": "fork/beid"}
        self.assertIsNone(self.resolve())
        self.assertEqual(self.calls, [])

    def test_full_mode_requires_real_full_lanes_and_a_passing_source_ledger(self):
        self.record(self.old, "full")
        self.assertEqual(self.resolve("full")["mode"], "full")
        self.jobs[self.old][-1]["conclusion"] = "failure"
        self.assertIsNone(self.resolve("full"))
        self.jobs[self.old].pop()
        self.assertIsNone(self.resolve("full"))

    def test_aggregate_names_tested_and_current_shas_and_keeps_a_prior_failure_red(self):
        previous = self.resolve()
        plan = {"run": "false", "mode": "smoke", "previous": json.dumps(previous)}
        needs = {"plan": {"result": "success", "outputs": plan},
                 "changes": {"result": "success", "outputs": {"ios": "true", "error": "false"}},
                 "build": {"result": "skipped"}, "tests": {"result": "skipped"}}
        message = validate_aggregate("pull_request", needs, None, {}, self.new)
        for value in (self.new, self.old, "run 80", "attempt 1", "smoke"):
            self.assertIn(value, message)
        for event in ("merge_group", "workflow_dispatch", "schedule", "push"):
            with self.subTest(event=event), self.assertRaises(ValueError):
                validate_aggregate(event, needs, None, {}, self.new)
        with mock.patch.dict(needs["build"], result="failure"), self.assertRaises(ValueError):
            validate_aggregate("pull_request", needs, None, {}, self.new)
        plan["previous"] = json.dumps({**previous, "conclusion": "failure"})
        with self.assertRaisesRegex(ValueError, "Prior iOS check did not pass"):
            validate_aggregate("pull_request", needs, None, {}, self.new)
