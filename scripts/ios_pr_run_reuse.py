"""Find directly executed PR iOS evidence. An empty result requests normal CI."""

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import urlencode

from scripts.ci_change_filter import safe_ios_reuse_changes

WORKFLOW = ".github/workflows/pr-ci-ios-macos.yml"
SHA = re.compile("[0-9a-f]{40}")


def provenance(number, base, sha, mode):
    return f"iOS plan v1 PR {number} base {base} head {sha} mode {mode}"


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


def previous_run(event, mode, repo, current_id, api):
    action = event["action"]
    if action not in ("ready_for_review", "synchronize") or mode not in ("full", "smoke"):
        return None
    number, pr = event["number"], event["pull_request"]
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
                or run["conclusion"] not in ("success", "failure")):
            return None
        if action == "synchronize" and (sha == head["sha"] or run["conclusion"] != "success" or attempt != 1):
            return None
        response = api(f"actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100")
        jobs = {job["name"]: job for job in response["jobs"]}
        if (len(jobs) != response["total_count"]
                or any(job["head_sha"] != sha or job["run_id"] != run_id for job in jobs.values())):
            return None
        plan = jobs.get("Plan iOS test jobs", {})
        gate = jobs.get("iOS simulator", {})
        actual_mode = executed_mode(jobs)
        if ("iOS simulator (inactive)" in jobs or successful_step(plan, "Use prior iOS execution")) and not actual_mode:
            continue  # Compare the actual tested ancestor directly on repeated documentation edits.
        stamped = successful_step(plan, provenance(number, base["sha"], sha, mode))
        if not stamped:
            # A completed, executed run on the identical SHA can predate the
            # plan marker. Cross-SHA reuse always needs immutable base provenance.
            opposite = "full" if mode == "smoke" else "smoke"
            if (successful_step(plan, provenance(number, base["sha"], sha, opposite))
                    or action == "ready_for_review" and actual_mode == opposite and run["conclusion"] == "success"):
                continue
            if any(s.get("conclusion") == "success" and s["name"].startswith("iOS plan v1 PR ")
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
        if sha != head["sha"]:
            # Reject PRs that modify the CI code used to produce or verify a
            # receipt, even when the most recent commit changes only prose.
            files = api(f"compare/{base['sha']}...{head['sha']}")["files"]
            if not isinstance(files, list) or not 0 < len(files) < 300:
                return None
            for entry in files:
                if (not isinstance(entry, dict) or not isinstance(entry.get("filename"), str)
                        or entry.get("status") not in ("added", "modified") or entry.get("previous_filename")):
                    return None
                path = entry["filename"]
                if safe_ios_reuse_changes([entry]):
                    continue
                # Changing the build graph could turn a normally independent
                # file into a test or bundle input. Accept only product source
                # outside the allowlisted independent roots.
                if not ((path.startswith(("ios/Beid/", "ios/BeidTests/", "ios/BeidUITests/"))
                         and path.endswith(".swift")) or (path.startswith("shared/src/") and path.endswith(".kt"))):
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
        result = previous_run(event, sys.argv[1], repo, int(os.environ["GITHUB_RUN_ID"]), api)
    except (AttributeError, KeyError, TypeError, ValueError, OSError, subprocess.SubprocessError):
        print("Prior iOS evidence unavailable. Running the normal lane.", file=sys.stderr)
        return
    if result:
        print("previous=" + json.dumps(result, separators=(",", ":")))


if __name__ == "__main__":
    main()
