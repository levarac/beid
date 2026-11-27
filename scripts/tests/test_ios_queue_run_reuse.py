"""Verify the main push can reuse only an executed full merge-queue run."""
import io
import json
import os
import subprocess
from contextlib import redirect_stdout
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest import TestCase, mock

from scripts import ios_pr_run_reuse as reuse, ios_ui_smoke
from scripts.ios_ui_smoke import validate_aggregate
from scripts.tests.workflow_yaml import named_step, workflow_data


class QueueEvidenceTests(TestCase):
    def setUp(self):
        self.sha = "b" * 40
        self.repo = "levarac/beid"
        identity = {"full_name": self.repo}
        self.event = {"repository": identity, "ref": "refs/heads/main", "after": self.sha,
                      "forced": False, "deleted": False, "created": False}
        self.push = {"id": 12, "workflow_id": 99, "event": "push", "path": reuse.WORKFLOW,
                     "head_sha": self.sha, "head_branch": "main", "repository": identity,
                     "created_at": "2026-11-27T01:10:16Z", "run_attempt": 1}
        self.source = {**self.push, "id": 10, "event": "merge_group",
                       "head_branch": "gh-readonly-queue/main/pr-42-" + "a" * 40,
                       "head_repository": identity, "status": "completed", "conclusion": "success",
                       "updated_at": "2026-11-27T01:10:15Z"}
        self.runs = [self.source]
        self.jobs = []
        for name, step in [
            ("Plan iOS test jobs", "Plan bounded test matrix"),
            ("Build iOS test bundles", "Build for testing"),
            *((f"iOS full tests ({lane})", "Execute full-mode test lane")
              for lane in ("unit", "ui-1", "ui-2", "ui-3", "ui-4")),
            ("iOS simulator", "Verify all job results and execution ledger"),
        ]:
            self.jobs.append({"name": name, "run_id": 10, "run_attempt": 1, "head_sha": self.sha,
                              "conclusion": "success", "steps": [{"name": step, "conclusion": "success"}]})

    def api(self, path):
        if path == f"actions/runs/{self.push['id']}":
            return self.push
        if path.startswith("actions/workflows/pr-ci-ios-macos.yml/runs?"):
            self.assertIn("event=merge_group", path)
            self.assertIn("head_sha=" + self.sha, path)
            return {"workflow_runs": self.runs, "total_count": len(self.runs)}
        if path == f"actions/runs/{self.source['id']}/attempts/{self.source['run_attempt']}/jobs?per_page=100":
            return {"jobs": self.jobs, "total_count": len(self.jobs)}
        self.fail(f"Unexpected API path: {path}")

    def lookup(self):
        return reuse.previous_queue_run(self.event, self.repo, self.push["id"], self.api, self.sha)

    def test_main_push_planner_outputs_a_receipt_and_falls_back_on_api_failure(self):
        with TemporaryDirectory() as temp:
            event_path = Path(temp) / "event.json"
            event_path.write_text(json.dumps(self.event))
            env = {"GITHUB_EVENT_PATH": str(event_path), "GITHUB_EVENT_NAME": "push",
                   "GITHUB_REPOSITORY": self.repo, "GITHUB_SHA": self.sha, "GITHUB_RUN_ID": "12",
                   "GITHUB_REF": "refs/heads/main", "GITHUB_RUN_ATTEMPT": "1"}

            def respond(cmd, **kwargs):
                result = self.api(cmd[-1].removeprefix(f"repos/{self.repo}/"))
                return mock.Mock(stdout=json.dumps(result))

            with mock.patch.dict(os.environ, env), mock.patch("sys.argv", ["planner", "full"]):
                output = io.StringIO()
                with mock.patch.object(reuse.subprocess, "run", side_effect=respond), redirect_stdout(output):
                    reuse.main()
                self.assertIn("previous=", output.getvalue())
                output = io.StringIO()
                with mock.patch.object(reuse.subprocess, "run", side_effect=TimeoutError), redirect_stdout(output):
                    reuse.main()
                self.assertEqual(output.getvalue(), "")
                for override in [{"GITHUB_EVENT_NAME": event} for event in ("merge_group", "schedule", "workflow_dispatch")] + [
                    {"GITHUB_RUN_ATTEMPT": "2"}, {"GITHUB_REF": "refs/heads/release/1.1.0"}
                ]:
                    with self.subTest(override=override), mock.patch.dict(os.environ, override), \
                            mock.patch.object(reuse.subprocess, "run") as gh, redirect_stdout(output):
                        reuse.main()
                        gh.assert_not_called()
                        self.assertEqual(output.getvalue(), "")

    def test_workflow_plans_one_mac_build_for_a_queue_and_its_proven_push(self):
        workflow = workflow_data(Path(reuse.WORKFLOW).read_text())
        planner = named_step(workflow, "plan", "Plan bounded test matrix")
        jobs = workflow["jobs"]
        self.assertEqual(planner["env"]["PREVIOUS"], "${{ steps.previous.outputs.previous }}")
        lookup, = (step for step in jobs["plan"]["steps"] if step.get("id") == "previous")
        self.assertIn("github.event_name == 'push' && github.ref == 'refs/heads/main'", lookup["if"])
        self.assertIn("needs.plan.outputs.run == 'true'", jobs["build"]["if"])
        self.assertIn("needs.build.result == 'success'", jobs["tests"]["if"])
        self.assertEqual(jobs["ios-simulator"]["if"], "${{ always() }}")
        for event, previous, expected in [("merge_group", "", "true"), ("push", json.dumps(self.lookup()), "false"),
                                          ("push", "", "true"), ("workflow_dispatch", "", "true"), ("schedule", "", "true")]:
            with self.subTest(event=event, expected=expected), TemporaryDirectory() as temp:
                path = Path(temp) / "output"
                subprocess.run(["bash", "-c", planner["run"]], check=True,
                               env={**os.environ, "EVENT_NAME": event, "GITHUB_OUTPUT": str(path), "IOS_UI_SHARDS": "4",
                                    "CHANGES_JSON": '{"result":"skipped"}', "PREVIOUS": previous})
                fields = dict(line.split("=", 1) for line in path.read_text().splitlines())
                self.assertEqual(fields["run"], expected)
                self.assertEqual(json.loads(fields["matrix"])["lane"], ["unit", "ui-1", "ui-2", "ui-3", "ui-4"])

    def test_full_queue_success_is_reported_on_the_main_push_only(self):
        receipt = self.lookup()
        self.assertEqual(receipt, dict(run_id=10, attempt=1, sha=self.sha, mode="full",
                                       conclusion="success", source_event="merge_group"))
        plan = {"run": "false", "mode": "full", "previous": json.dumps(receipt)}
        needs = {"changes": {"result": "skipped"}, "plan": {"result": "success", "outputs": plan},
                 "build": {"result": "skipped"}, "tests": {"result": "skipped"}}
        message = validate_aggregate("push", needs, None, {}, self.sha, ref="refs/heads/main")
        for value in (self.sha, "merge_group", "run 10", "attempt 1"):
            self.assertIn(value, message)
        with TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "evidence").mkdir()
            (root / "needs.json").write_text(json.dumps(needs))
            args = ["tool", "aggregate", "--event-name", "push", "--sha", self.sha, "--attempt", "1",
                    "--evidence-root", str(root / "evidence"), "--needs-json", str(root / "needs.json"),
                    "--summary", str(root / "summary")]
            env = {"GITHUB_REF": "refs/heads/main", "GITHUB_SERVER_URL": "https://github.com", "GITHUB_REPOSITORY": self.repo}
            with mock.patch.dict(os.environ, env), mock.patch("sys.argv", args), redirect_stdout(io.StringIO()):
                self.assertEqual(ios_ui_smoke.main(), 0)
            self.assertIn("https://github.com/levarac/beid/actions/runs/10/attempts/1", (root / "summary").read_text())
        for event, ref, sha in [("merge_group", "refs/heads/main", self.sha),
                                ("pull_request", "refs/heads/main", self.sha),
                                ("workflow_dispatch", "refs/heads/main", self.sha),
                                ("schedule", "refs/heads/main", self.sha),
                                ("push", "refs/heads/release/1.1.0", self.sha),
                                ("push", "refs/heads/main", "a" * 40)]:
            with self.subTest(event=event, ref=ref, sha=sha), self.assertRaises(ValueError):
                validate_aggregate(event, needs, None, {}, sha, ref=ref)

    def test_partial_rerun_on_the_four_shard_merge_queue(self):
        self.assert_partial_queue_rerun(ui_shards=4)

    def test_partial_rerun_with_the_pre_912_five_shard_matrix(self):
        self.assert_partial_queue_rerun(ui_shards=5)

    def assert_partial_queue_rerun(self, *, ui_shards):
        # PR #945 run 45900966547 supplied the attempt-2 job IDs and times
        # for the pre-#912 matrix. The current queue replay omits ui-5.
        # The queue event, its SHA and the subsequent main push are synthetic.
        run_id = 45900966547
        self.sha = "f9b11d1170bf9b94245ad250f3926623efc4cf79"
        self.event["after"] = self.sha
        self.push.update(id=run_id + 1, head_sha=self.sha)
        self.source.update(id=run_id, head_sha=self.sha, run_attempt=2, created_at="2026-11-26T21:51:32Z",
                           run_started_at="2026-11-26T22:59:22Z", updated_at="2026-11-27T00:00:25Z")
        attempt_jobs = {
            # GitHub reissued these jobs under attempt 2 with their original times.
            "Plan iOS test jobs": (140209912409, "2026-11-26T21:51:48Z"),
            "Build iOS test bundles": (140209920651, "2026-11-26T21:51:58Z"),
            "iOS full tests (unit)": (140209874688, "2026-11-26T22:09:25Z"),
            "iOS full tests (ui-1)": (140209874141, "2026-11-26T22:26:54Z"),
            "iOS full tests (ui-3)": (140209924105, "2026-11-26T22:09:24Z"),
            # ui-2, ui-4 and the aggregate ran again, as did ui-5 in the older matrix.
            "iOS full tests (ui-2)": (140209873159, "2026-11-26T23:21:05Z"),
            "iOS full tests (ui-4)": (140209873165, "2026-11-26T23:27:09Z"),
            "iOS full tests (ui-5)": (140209872937, "2026-11-26T23:05:21Z"),
            "iOS simulator": (140229250199, "2026-11-27T00:00:16Z"),
        }
        jobs = {job["name"]: job for job in self.jobs}
        if ui_shards == 5:
            jobs["iOS full tests (ui-5)"] = {**jobs["iOS full tests (ui-4)"], "name": "iOS full tests (ui-5)"}
        self.jobs = list(jobs.values())
        for name, job in jobs.items():
            job_id, started_at = attempt_jobs[name]
            job.update(id=job_id, started_at=started_at, run_id=run_id, head_sha=self.sha, run_attempt=2)

        self.assertEqual(self.lookup(), dict(run_id=run_id, attempt=2, sha=self.sha, mode="full",
                                             conclusion="success", source_event="merge_group"))
        # Only the final attempt's published evidence can be credited.
        with mock.patch.dict(jobs["Build iOS test bundles"], run_attempt=1):
            self.assertIsNone(self.lookup())
        with mock.patch.dict(jobs["iOS full tests (ui-2)"], steps=[]):
            self.assertIsNone(self.lookup())

    def test_source_requires_same_workflow_repo_commit_queue_and_prior_success(self):
        for fields in [
            {"event": "pull_request"}, {"path": "other.yml"}, {"workflow_id": 1},
            {"head_sha": "f" * 40}, {"head_branch": "gh-readonly-queue/release/pr-42"},
            {"head_repository": {"full_name": "other/repo"}}, {"id": 13}, {"status": "in_progress"},
            {"conclusion": "failure"}, {"conclusion": "cancelled"},
            {"updated_at": "2026-11-27T01:10:17Z"},
        ]:
            with self.subTest(fields=fields), mock.patch.dict(self.source, fields):
                self.assertIsNone(self.lookup())
        self.runs.append({**self.source, "id": 11, "conclusion": "failure"})
        self.assertIsNone(self.lookup())

    def test_no_receipt_for_other_refs_reruns_or_missing_execution(self):
        for fields in [{"ref": "refs/heads/release/1.1.0"}, {"after": "a" * 40},
                       {"forced": True}, {"created": True}, {"deleted": True}]:
            with self.subTest(fields=fields), mock.patch.dict(self.event, fields):
                self.assertIsNone(self.lookup())
        with mock.patch.dict(self.push, run_attempt=2):
            self.assertIsNone(self.lookup())
        for job in self.jobs:
            with self.subTest(job=job["name"]), mock.patch.dict(job, conclusion="skipped"):
                self.assertIsNone(self.lookup())
        for fields in [{"steps": []}, {"head_sha": "a" * 40}, {"run_id": 11}, {"run_attempt": 2}]:
            with self.subTest(fields=fields), mock.patch.dict(self.jobs[-1], fields):
                self.assertIsNone(self.lookup())
        with mock.patch.dict(self.jobs[0], steps=[*self.jobs[0]["steps"], {"name": "Use prior iOS execution", "conclusion": "success"}]):
            self.assertIsNone(self.lookup())
        self.jobs.append({**self.jobs[2], "name": "iOS full tests (ui-5)", "conclusion": "skipped"})
        self.assertIsNone(self.lookup())
        self.jobs.pop()
        self.jobs.append(self.jobs[-1])
        self.assertIsNone(self.lookup())
