"""Pin the release nightly and recognize only complete, exact-commit iOS evidence."""

import argparse
from collections import Counter
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import zipfile

BRANCH = "release/1.1.0"
NIGHTLY = "release-ios-nightly.yml"
PR_WORKFLOW = "pr-ci-ios-macos.yml"
OBSERVED = "release-observation-"
SHA = re.compile(r"[0-9a-f]{40}")
EVIDENCE_ERRORS = (
    OSError,
    ValueError,
    TypeError,
    KeyError,
    RuntimeError,
    zipfile.BadZipFile,
    subprocess.SubprocessError,
)


def valid_sha(value):
    if not isinstance(value, str) or not SHA.fullmatch(value):
        raise ValueError("invalid release commit")
    return value


class Actions:
    def __init__(self, repo):
        self.repo = repo
        self.deadline = time.monotonic() + 240

    def read(self, path):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("evidence lookup deadline reached")
        return subprocess.check_output(
            ["gh", "api", f"repos/{self.repo}/{path}"], timeout=min(45, remaining)
        )

    def objects(self, path, key):
        join = "&" if "?" in path else "?"
        page = 1
        while True:
            items = json.loads(self.read(f"{path}{join}per_page=100&page={page}"))[key]
            yield from items
            if len(items) < 100:
                return
            page += 1

    def runs(self, workflow, query):
        return self.objects(f"actions/workflows/{workflow}/runs?{query}", "workflow_runs")

    def artifacts(self, run_id):
        return {
            a["name"]: a
            for a in self.objects(f"actions/runs/{run_id}/artifacts", "artifacts")
            if not a["expired"]
        }

    def files(self, artifact, *names):
        if artifact["size_in_bytes"] > 40 * 1024**2:
            raise ValueError("oversized evidence")
        with zipfile.ZipFile(
            io.BytesIO(self.read(f"actions/artifacts/{int(artifact['id'])}/zip"))
        ) as archive:
            result = {}
            for name in names:
                info = archive.getinfo(name)
                if info.file_size > 16 * 1024**2 or archive.namelist().count(name) != 1:
                    raise ValueError("ambiguous or oversized JSON evidence")
                result[name] = json.loads(archive.read(info))
            return result


def observation(api, run_id, attempt=None):
    artifacts = api.artifacts(run_id)
    matches = []
    for name, artifact in artifacts.items():
        if match := re.fullmatch(OBSERVED + r"([1-9]\d*)", name):
            number = int(match[1])
            if attempt is None or number < attempt:
                matches.append((number, artifact))
    if not matches:
        return None
    number, artifact = max(matches, key=lambda item: item[0])
    data = api.files(artifact, "observation.json")["observation.json"]
    if (data["branch"], data["run_id"], data["attempt"]) != (BRANCH, run_id, number):
        raise ValueError("observation identity mismatch")
    return valid_sha(data["sha"])


def pin(api, run_id, attempt):
    if attempt > 1:
        # A retry cannot silently test a different commit after the branch moves.
        pinned = observation(api, run_id, attempt)
        if not pinned:
            raise ValueError("the original observation is unavailable on this retry")
        return pinned
    ref = json.loads(api.read(f"git/ref/heads/{BRANCH}"))
    if ref["ref"] != f"refs/heads/{BRANCH}" or ref["object"]["type"] != "commit":
        raise ValueError("release ref is missing or is not a commit")
    return valid_sha(ref["object"]["sha"])


def previous(api, run_number):
    # Only this dedicated schedule uses the workflow's run numbers. A rerun
    # keeps its number; never treat the current attempt as the previous night.
    prior = next(
        (r for r in api.runs(NIGHTLY, "event=schedule") if r["run_number"] == run_number - 1), None
    )
    if prior is None:
        raise ValueError("preceding scheduled run absent")
    sha = observation(api, prior["id"])
    if not sha:
        raise ValueError("preceding observation missing or expired")
    return sha


def inventory(manifest, sha, suite):
    if manifest.get("sha") != sha or manifest.get("mode") != "full":
        raise ValueError("wrong commit or test mode")
    unit = suite.unique_tests(manifest["unit"], "BeidTests")
    ui = suite.unique_tests(manifest["ui"], "BeidUITests")
    iphone = suite.parse_smoke_list(suite.IPHONE_SKIPS.read_text())
    debug = [
        identifier
        for line in suite.UNIT_SKIPS.read_text().splitlines()
        if (identifier := line.partition("#")[0].strip())
    ]
    if (
        set(iphone) != set(manifest["iphone_skips"])
        or set(debug) != set(manifest["unit_skips"])
        or not set(iphone) <= set(ui)
        or not set(debug) <= set(unit)
    ):
        raise ValueError("environment exclusions differ from the release")
    return unit, ui, iphone + debug


def verify_single(manifest, enumeration, tree, sha, suite):
    unit, ui, skips = inventory(manifest, sha, suite)
    built = suite.parse_enumeration(enumeration)
    if unit != sorted(built["BeidTests"]) or ui != sorted(built["BeidUITests"]):
        raise ValueError("full manifest differs from built test bundles")
    cases = suite.validate_lane(unit + ui, tree, skips)
    return {
        "sha": sha,
        "mode": "full",
        "unit": len(unit),
        "ui": len(ui),
        "passed": sum(c[1] == "Passed" for c in cases),
        "skipped": len(skips),
    }


def passed_pr(api, run, sha, suite):
    if run["head_sha"] != sha or run["status"] != "completed" or run["conclusion"] != "success":
        return False
    artifacts = api.artifacts(run["id"])
    # A successful rerun may reuse earlier shards. This conservative check only
    # suppresses a nightly when one attempt retains all of its own evidence.
    prefix = f"ios-evidence-{run['run_attempt']}-"
    build = api.files(artifacts[prefix + "build"], "manifest.json", "enumerated-tests.json")
    manifest = build["manifest.json"]
    unit, ui, skips = inventory(manifest, sha, suite)
    enumeration = suite.parse_enumeration(build["enumerated-tests.json"])
    if unit != sorted(enumeration["BeidTests"]) or ui != sorted(enumeration["BeidUITests"]):
        return False
    shards = suite.ui_shard_lanes(manifest["shards"])
    if Counter(test for shard in shards.values() for test in shard) != Counter(ui):
        return False
    lanes = {"unit": unit, **shards}
    names = {"iOS simulator", "Build iOS test bundles", *(f"iOS full tests ({k})" for k in lanes)}
    jobs = api.objects(f"actions/runs/{run['id']}/attempts/{run['run_attempt']}/jobs", "jobs")
    if not names <= {j["name"] for j in jobs if j["conclusion"] == "success"}:
        return False
    for lane, expected in lanes.items():
        data = api.files(artifacts[prefix + lane], "manifest.json", "test-tree.json")
        if data["manifest.json"] != manifest:
            return False
        suite.validate_lane(expected, data["test-tree.json"], skips)
    return True


def exact_pass(api, sha, suite):
    for run in api.runs(PR_WORKFLOW, f"head_sha={sha}&status=success"):
        try:
            if passed_pr(api, run, sha, suite):
                return run["id"]
        except EVIDENCE_ERRORS:
            continue
    # Scheduled run metadata identifies main. A named artifact locates the
    # producer, and its manifest and case tree prove which SHA actually ran.
    named = api.objects(f"actions/artifacts?name=release-full-{sha}", "artifacts")
    for artifact in named:
        if artifact["expired"]:
            continue
        try:
            run = json.loads(api.read(f"actions/runs/{int(artifact['workflow_run']['id'])}"))
            if (run["event"], run["path"], run["status"], run["conclusion"]) != (
                "schedule",
                f".github/workflows/{NIGHTLY}",
                "completed",
                "success",
            ):
                continue
            data = api.files(artifact, "manifest.json", "enumerated-tests.json", "test-tree.json")
            verify_single(
                data["manifest.json"],
                data["enumerated-tests.json"],
                data["test-tree.json"],
                sha,
                suite,
            )
            return run["id"]
        except EVIDENCE_ERRORS:
            continue
    return None


def decide(api, sha, run_number, suite):
    if run_number == 1:
        reason = "first scheduled run"
    else:
        try:
            prior = previous(api, run_number)
        except EVIDENCE_ERRORS:
            reason = "previous observation unreadable, checking exact full pass"
        else:
            if prior == sha:
                return False, "unchanged since previous observation"
            reason = f"head changed from {prior}"
    try:
        passed = exact_pass(api, sha, suite)
        if passed:
            return False, f"{reason}, verified full pass in run {passed}"
        return True, f"{reason}, no verified full pass"
    except EVIDENCE_ERRORS:
        return True, f"{reason}, full-pass evidence unavailable"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["pin", "decide", "verify"])
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=True)
    if args.operation == "pin":
        api = Actions(os.environ["GITHUB_REPOSITORY"])
        run_id, attempt = int(os.environ["GITHUB_RUN_ID"]), int(os.environ["GITHUB_RUN_ATTEMPT"])
        sha = pin(api, run_id, attempt)
        (args.evidence / "observation.json").write_text(
            json.dumps({"branch": BRANCH, "sha": sha, "run_id": run_id, "attempt": attempt}) + "\n"
        )
        output = f"sha={sha}"
        summary = f"Observed {BRANCH} at {sha}."
    else:
        sys.path.insert(0, str(Path.cwd()))
        from scripts import ios_ui_smoke as suite

        sha = valid_sha(os.environ["RELEASE_SHA"])
        if subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip() != sha:
            raise ValueError("checkout differs from the resolved release")
        if args.operation == "decide":
            run, reason = decide(
                Actions(os.environ["GITHUB_REPOSITORY"]),
                sha,
                int(os.environ["GITHUB_RUN_NUMBER"]),
                suite,
            )
            output = f"run={str(run).lower()}"
            summary = f"{BRANCH} {sha}: {reason}. Execute tests: {run}."
        else:
            manifest, enumeration, tree = [
                json.loads((args.evidence / name).read_text())
                for name in ("manifest.json", "enumerated-tests.json", "test-tree.json")
            ]
            result = verify_single(manifest, enumeration, tree, sha, suite)
            output = "verified=true"
            summary = f"{BRANCH} {sha}: full, {result['unit']} unit + {result['ui']} UI, {result['passed']} passed, {result['skipped']} expected skips."
    print(summary)
    for key, text in (("GITHUB_OUTPUT", output), ("GITHUB_STEP_SUMMARY", summary)):
        with open(os.environ[key], "a") as stream:
            print(text, file=stream)


if __name__ == "__main__":
    main()
