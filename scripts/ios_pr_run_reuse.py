"""Find directly executed iOS evidence. An empty result requests normal CI."""

import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from urllib.parse import urlencode

from scripts.ci_change_filter import _requires_full_ios, safe_ios_reuse_changes

WORKFLOW = ".github/workflows/pr-ci-ios-macos.yml"
SHA = re.compile("[0-9a-f]{40}")


def provenance(number, base, sha, mode):
    return f"iOS plan v2 PR {number} base {base} head {sha} mode {mode} merge "


def stamped_merge(plan, number, base, sha, mode):
    prefix = provenance(number, base, sha, mode)
    matches = [step["name"][len(prefix):] for step in plan.get("steps") or []
               if step.get("conclusion") == "success" and step["name"].startswith(prefix)]
    if len(matches) == 1 and SHA.fullmatch(matches[0]):
        return matches[0]
    return None


def workflow_blob(api, merge, base, head):
    """Resolve the workflow read by Actions on this particular test merge."""
    if not isinstance(merge, str) or not SHA.fullmatch(merge):
        return None
    commit = api(f"git/commits/{merge}")
    if commit["sha"] != merge or [parent["sha"] for parent in commit["parents"]] != [base, head]:
        return None
    item = api(f"contents/{WORKFLOW}?ref={merge}")
    if item.get("type") == "file" and item.get("path") == WORKFLOW and SHA.fullmatch(item["sha"]):
        return item["sha"]
    return None


def successful_step(job, name):
    return any(step.get("name") == name and step.get("conclusion") == "success"
               for step in job.get("steps") or [])


def executed_mode(jobs):
    build = jobs.get("Build iOS test bundles", {})
    if build.get("conclusion") != "success" or not successful_step(build, "Build for testing"):
        return None
    lanes = {name: job for name, job in jobs.items() if name.startswith("iOS full tests (")
             and job.get("conclusion") != "skipped"}
    if not lanes:
        if successful_step(build, "Test without rebuilding") and successful_step(build, "Verify UI execution and bundle durations"):
            return "smoke"
    elif (not successful_step(build, "Test without rebuilding")
          and any(set(lanes) == {"iOS full tests (unit)", *(f"iOS full tests (ui-{i})" for i in range(1, count + 1))}
                  for count in (4, 5))
          and all(job.get("conclusion") == "success" and successful_step(job, "Execute full-mode test lane")
                  for job in lanes.values())):
        # The source aggregate checks the exact shard set and every case ID.
        return "full"
    return None


def attempt_jobs(api, run):
    run_id, attempt = run["id"], run["run_attempt"]
    response = api(f"actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100")
    jobs = {job["name"]: job for job in response["jobs"]}
    if (len(jobs) != len(response["jobs"]) or len(jobs) != response["total_count"] or
            any(job["head_sha"] != run["head_sha"] or job["run_id"] != run_id for job in jobs.values())):
        return {}
    return jobs


def previous_queue_run(event, repo, current_id, api, sha):
    if (event["ref"] != "refs/heads/main" or event["repository"]["full_name"] != repo
            or event["after"] != sha or not SHA.fullmatch(sha)
            or any(event[flag] is not False for flag in ("created", "deleted", "forced"))):
        return None
    push = api(f"actions/runs/{current_id}")
    if (push["id"] != current_id or push["run_attempt"] != 1 or push["event"] != "push"
            or push["head_branch"] != "main" or push["head_sha"] != sha or push["path"] != WORKFLOW
            or push["repository"]["full_name"] != repo):
        return None
    query = urlencode({"event": "merge_group", "head_sha": sha, "per_page": 100})
    result = api("actions/workflows/pr-ci-ios-macos.yml/runs?" + query)
    runs = result["workflow_runs"]
    if len(runs) != result["total_count"]:
        return None
    # Inspect the latest matching queue run, including failing or incomplete runs.
    # Filtering to successes here could hide a newer negative result.
    run = max((r for r in runs if 0 < r["id"] < current_id and r["event"] == "merge_group"
               and r["head_sha"] == sha and r["head_branch"].startswith("gh-readonly-queue/main/")
               and r["path"] == WORKFLOW and r["workflow_id"] == push["workflow_id"]
               and r["repository"]["full_name"] == repo and r["head_repository"]["full_name"] == repo),
              key=lambda r: r["id"], default=None)
    if (not run or run["status"] != "completed" or run["conclusion"] != "success"
            or type(run["run_attempt"]) is not int or run["run_attempt"] < 1
            or datetime.strptime(run["updated_at"], "%Y-%m-%dT%H:%M:%SZ")
            > datetime.strptime(push["created_at"], "%Y-%m-%dT%H:%M:%SZ")):
        return None
    jobs = attempt_jobs(api, run)
    plan = jobs.get("Plan iOS test jobs", {})
    gate = jobs.get("iOS simulator", {})
    if (any(job["run_attempt"] != run["run_attempt"] for job in jobs.values())
            or plan.get("conclusion") != "success" or not successful_step(plan, "Plan bounded test matrix")
            or successful_step(plan, "Use prior iOS execution")
            or any(job["conclusion"] != "success" for name, job in jobs.items() if name.startswith("iOS full tests ("))
            or executed_mode(jobs) != "full" or gate.get("conclusion") != "success"
            or not successful_step(gate, "Verify all job results and execution ledger")):
        return None
    return {"run_id": run["id"], "attempt": run["run_attempt"], "sha": sha, "mode": "full",
            "conclusion": "success", "source_event": "merge_group"}


def eligible_pr_changes(files, *, cross_head, mode):
    if not isinstance(files, list) or not 0 < len(files) < 300:
        return False
    policy = {WORKFLOW, "scripts/ios_pr_run_reuse.py", "scripts/ci_change_filter.py", "scripts/ios_ui_smoke.py"}
    for entry in files:
        if not isinstance(entry, dict) or not isinstance(entry.get("filename"), str):
            return False
        path = entry["filename"]
        previous, status = entry.get("previous_filename"), entry.get("status")
        if path in policy or previous in policy:
            return False
        if not cross_head:
            if status not in ("added", "modified", "removed", "renamed") or (status == "renamed") != bool(previous):
                return False
            continue  # On ready both runs tested the identical tree, including removals.
        if status not in ("added", "modified") or previous:
            return False
        if mode == "smoke" and _requires_full_ios(path):
            return False
        if not safe_ios_reuse_changes([entry]):
            # A change to the build graph could create a new dependency on
            # a normally independent path. Only accept known product sources.
            swift = path.startswith(("ios/Beid/", "ios/BeidTests/", "ios/BeidUITests/")) and path.endswith(".swift")
            kotlin = path.startswith("shared/src/") and path.endswith(".kt")
            if not (swift or kotlin):
                return False
    return True


def previous_run(event, mode, repo, current_id, api, current_merge):
    action = event["action"]
    if action not in ("ready_for_review", "synchronize") or mode not in ("full", "smoke"):
        return None
    number, pr = event["number"], event["pull_request"]
    if action == "synchronize" and (not isinstance(pr.get("labels"), list)
                                    or any(label["name"] == "ci:full-ui" for label in pr["labels"])):
        return None
    base, head = pr["base"], pr["head"]
    if (base["repo"]["full_name"] != repo or head["repo"]["full_name"] != repo
            or not SHA.fullmatch(head["sha"]) or not SHA.fullmatch(base["sha"])):
        return None
    query = urlencode({"event": "pull_request", "branch": head["ref"], "per_page": 30})
    runs = api("actions/workflows/pr-ci-ios-macos.yml/runs?" + query)["workflow_runs"]
    for run in sorted(runs, key=lambda item: (item["updated_at"], item["id"]), reverse=True):
        sha, run_id = run["head_sha"], run["id"]
        if (run_id >= current_id or run["event"] != "pull_request" or run["path"] != WORKFLOW
                or run["head_branch"] != head["ref"] or run["head_repository"]["full_name"] != repo
                or not any(link.get("number") == number and link["base"]["ref"] == base["ref"]
                           for link in run["pull_requests"])):
            continue
        if action == "ready_for_review" and sha != head["sha"]:
            continue
        attempt = run["run_attempt"]
        if (not SHA.fullmatch(sha) or run["status"] != "completed" or type(attempt) is not int or attempt < 1
                or run["conclusion"] not in ("success", "failure", "skipped")):
            return None
        jobs = attempt_jobs(api, run)
        if not jobs:
            return None
        plan = jobs.get("Plan iOS test jobs", {})
        gate = jobs.get("iOS simulator", {})
        actual_mode = executed_mode(jobs)
        inactive = jobs.get("iOS simulator (inactive)")
        if inactive and not gate and all(job["conclusion"] == "skipped" for job in jobs.values() if job is not inactive):
            if (inactive["conclusion"] == "skipped" or
                    inactive["conclusion"] == "success" and successful_step(inactive, "Record inactive PR event")):
                continue
        if run["conclusion"] == "skipped":
            return None
        if successful_step(plan, "Use prior iOS execution") and not actual_mode and gate.get("conclusion") == "success":
            continue  # Compare the actual tested ancestor directly on repeated documentation edits.
        if action == "synchronize" and (sha == head["sha"] or run["conclusion"] != "success" or attempt != 1):
            return None
        stamped = stamped_merge(plan, number, base["sha"], sha, mode)
        if not stamped:
            # A completed, executed run on the identical SHA can predate the
            # plan marker. Cross-SHA reuse always needs immutable base provenance.
            opposite = "full" if mode == "smoke" else "smoke"
            if (stamped_merge(plan, number, base["sha"], sha, opposite)
                    or action == "ready_for_review" and actual_mode == opposite and run["conclusion"] == "success"):
                continue
            if any(s.get("conclusion") == "success" and s["name"].startswith("iOS plan v2 PR ")
                   for s in plan.get("steps") or []):
                return None  # Recorded provenance differs from the current base/PR.
            if action != "ready_for_review" or actual_mode != mode:
                return None
        outcome = gate.get("conclusion")
        if outcome == "success":
            if (run["conclusion"] != "success" or actual_mode != mode
                    or not successful_step(gate, "Verify all job results and execution ledger")):
                return None
        elif not (action == "ready_for_review" and outcome == run["conclusion"] == "failure"):
            return None
        files = api(f"compare/{base['sha']}...{head['sha']}")["files"]
        if not eligible_pr_changes(files, cross_head=sha != head["sha"], mode=mode):
            return None
        if sha != head["sha"]:
            source_blob = workflow_blob(api, stamped, base["sha"], sha)
            if not source_blob or source_blob != workflow_blob(api, current_merge, base["sha"], head["sha"]):
                return None
            comparison = api(f"compare/{sha}...{head['sha']}")
            if (comparison.get("status") != "ahead" or comparison["merge_base_commit"]["sha"] != sha
                    or not safe_ios_reuse_changes(comparison["files"])):
                return None
        return {"run_id": run_id, "attempt": attempt, "sha": sha, "mode": mode, "conclusion": outcome}
    return None


def main():
    repo = os.environ["GITHUB_REPOSITORY"]
    deadline = time.monotonic() + 45

    def api(route):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("evidence lookup budget exhausted")
        result = subprocess.run(["gh", "api", f"repos/{repo}/{route}"], capture_output=True,
                                text=True, timeout=min(15, remaining), check=True)
        return json.loads(result.stdout)

    try:
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        run_id, sha = int(os.environ["GITHUB_RUN_ID"]), os.environ["GITHUB_SHA"]
        if os.environ["GITHUB_EVENT_NAME"] == "push":
            if (sys.argv[1] != "full" or os.environ["GITHUB_REF"] != "refs/heads/main"
                    or os.environ["GITHUB_RUN_ATTEMPT"] != "1"):
                return
            result = previous_queue_run(event, repo, run_id, api, sha)
        elif os.environ["GITHUB_EVENT_NAME"] == "pull_request":
            result = previous_run(event, sys.argv[1], repo, run_id, api, sha)
        else:
            return
    except (AttributeError, KeyError, TypeError, ValueError, OSError, subprocess.SubprocessError):
        print("Prior iOS evidence unavailable. Running the normal lane.", file=sys.stderr)
        return
    if result:
        print("previous=" + json.dumps(result, separators=(",", ":")))


if __name__ == "__main__":
    main()
