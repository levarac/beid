"""Classify a saved hosted UI shard failure. This command never runs tests."""

import argparse
from collections import Counter
from datetime import datetime
import hashlib
import json
import math
from pathlib import Path, PurePosixPath
import plistlib
import re
import tarfile
import zipfile
import zlib
from xml.parsers.expat import ExpatError

from scripts.ios_ui_smoke import result_case_nodes, ui_shard_lanes, unique_tests

TEST_STEP = "Execute full-mode test lane"
VERIFY_STEP = "Collect shard structured results"
TERMINATE = re.compile(r"Failed to terminate org\.levarac\.beid:[1-9][0-9]*: Failed to terminate org\.levarac\.beid:0")
LAUNCH = re.compile(
    r"Failed to launch <XCUIApplicationImpl: 0x[0-9a-fA-F]+ org\.levarac\.beid at "
    r"(?P<root>/Users/runner/work/_temp/beid-[0-9]+-[0-9]+-ui-[1-5])"
    r"/DerivedData/Build/Products/Debug-iphonesimulator/Beid\.app> via Xcode: "
    r"Timed out while launching application via Xcode\."
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def failure_code(text, shard_root):
    if TERMINATE.fullmatch(text):
        return "app_termination_failed"
    match = LAUNCH.fullmatch(text)
    if match and match["root"] == shard_root:
        return "app_launch_timeout"
    raise ValueError("unrecognized XCTest failure")


def inspect_job(job, log, report):
    require(all(type(job[key]) is int and job[key] > 0 for key in ("id", "run_id", "run_attempt"))
            and re.fullmatch(r"[0-9a-f]{40}", job["head_sha"]), "missing job identity")
    lane = re.fullmatch(r"iOS full tests \((ui-[1-5])\)", job["name"])
    require(lane and job["status"] == "completed" and job["conclusion"] == "failure", "not a completed failed UI shard")
    require(job["runner_group_name"] == "GitHub Actions" and job["labels"] == ["xcode-27"] and job["runner_name"], "runner identity unavailable")
    steps = {step["name"]: step for step in job["steps"]}
    require(len(steps) == len(job["steps"]), "duplicate job step")
    for name in ("Validate and restore test products", "Create shard-owned simulator", "Boot shard-owned simulator",
                 "Upload shard test evidence", "Archive failed UI test result", "Upload failed UI test result",
                 "Delete shard-owned simulator"):
        require(steps[name]["conclusion"] == "success", "setup, evidence or cleanup incomplete")
    failures = {name for name, step in steps.items() if step["conclusion"] != "success"}
    require(failures == {TEST_STEP, VERIFY_STEP} and all(steps[n]["conclusion"] == "failure" for n in failures),
            "unexpected step outcomes")
    start, end = [datetime.fromisoformat(steps[TEST_STEP][key]) for key in ("started_at", "completed_at")]
    errors = re.findall(r"^(\S+) ##\[error\]([^\n]*)$", log, re.M)
    test_errors = [text for stamp, text in errors
                   if start <= datetime.fromisoformat(stamp).replace(microsecond=0) <= end]
    require(test_errors == ["Process completed with exit code 65."], "unexpected or missing XCTest exit evidence")
    require(not re.search(r"##\[error\].*(?:operation was cancel+ed|exceeded the maximum execution time|step was cancel+ed)", log, re.I),
            "job or step interrupted")
    image = re.findall(r"##\[group\]Runner Image\n\S+ Image: ([\w.-]+)\n\S+ Version: ([\w.-]+)\n", log)
    require(len(image) == 1 and image[0][0] == "xcode-27-arm64", "runner image unavailable or unsupported")
    report.update(run_id=job["run_id"], attempt=job["run_attempt"], job_id=job["id"], head=job["head_sha"],
                  lane=lane[1], runner=job["runner_name"], runner_label="xcode-27",
                  image=image[0][0], image_version=image[0][1], step_seconds=(end-start).total_seconds(),
                  job_seconds=(datetime.fromisoformat(job["completed_at"])-datetime.fromisoformat(job["started_at"])).total_seconds())
    return start.timestamp(), end.timestamp()+1


def artifact(root, kind, job, name):
    metadata = json.loads((root / f"{kind}.json").read_bytes())
    archive = root / f"{kind}.zip"
    require(metadata["name"] == name and metadata["workflow_run"]["id"] == job["run_id"]
            and metadata["workflow_run"]["head_sha"] == job["head_sha"]
            and type(metadata["id"]) is int and metadata["id"] > 0, "artifact identity mismatch")
    require(archive.stat().st_size == metadata["size_in_bytes"] > 0, "artifact size mismatch")
    with archive.open("rb") as data:
        digest = "sha256:" + hashlib.file_digest(data, "sha256").hexdigest()
    require(digest == metadata["digest"], "artifact digest mismatch")
    return {"id": metadata["id"], "name": name, "digest": digest}



def verify_result_bundle(path):
    """Inspect the stored tar in place. Never extract PR-controlled files."""
    with zipfile.ZipFile(path) as archive:
        require(archive.namelist() == ["Tests.xcresult.tar.gz"] and
                0 < archive.infolist()[0].file_size <= 250 * 1024**2, "xcresult archive missing or oversized")
        with archive.open("Tests.xcresult.tar.gz") as compressed, tarfile.open(fileobj=compressed, mode="r|gz") as tar:
            data_files = set()
            root_id = None
            total = 0
            for member in tar:
                name = PurePosixPath(member.name)
                total += member.size
                require(name.parts[:1] == ("Tests.xcresult",) and ".." not in name.parts
                        and (member.isdir() or member.isfile()) and total <= 1024**3, "invalid xcresult archive")
                if name.parts == ("Tests.xcresult", "Info.plist"):
                    require(member.isfile() and member.size <= 65536 and root_id is None, "invalid bundle metadata")
                    root_id = plistlib.loads(tar.extractfile(member).read())["rootId"]["hash"]
                elif name.parts[:2] == ("Tests.xcresult", "Data") and len(name.parts) == 3 and member.size:
                    data_files.add(name.name)
            require(isinstance(root_id, str) and "data." + root_id in data_files
                    and "refs." + root_id in data_files, "xcresult root object missing")


def inspect_results(manifest, summary, tree, report, times):
    require(manifest["sha"] == report["head"] and manifest["mode"] == "full", "manifest SHA or mode mismatch")
    ui = unique_tests(manifest["ui"], "BeidUITests")
    unique_tests(manifest["unit"], "BeidTests")
    lanes = ui_shard_lanes(manifest["shards"])
    inventory = [case for shard in lanes.values() for case in unique_tests(shard, "BeidUITests")]
    require(sorted(inventory) == ui, "manifest partition incomplete or duplicated")
    selected = lanes[report["lane"]]
    skips = manifest["iphone_skips"]
    require(isinstance(skips, list) and len(set(skips)) == len(skips) and set(skips) <= set(ui), "invalid skip list")

    config, = summary["devicesAndConfigurations"]
    device = config["device"]
    prefix = f'ci-beid-{report["run_id"]}-{report["attempt"]}-tests-{report["lane"]}-'
    require(device["deviceName"].startswith(prefix) and device["deviceId"] and device["modelName"] == "iPhone 18 Pro"
            and device["osVersion"] == "27.0" and device["platform"] == "iOS Simulator"
            and device["architecture"] == manifest["arch"] and tree["devices"] == [device]
            and tree["testPlanConfigurations"] == [config["testPlanConfiguration"]], "simulator identity mismatch")
    start, end = summary["startTime"], summary["finishTime"]
    require(all(type(n) in (float, int) and math.isfinite(n) for n in (start, end))
            and times[0] <= start < end <= times[1], "xcresult times outside the test step")
    report.update(simulator=device, xcode=manifest["xcode"], sdk=manifest["sdk"], xcresult_seconds=round(end-start, 3))
    require(report["xcode"] and report["sdk"], "missing toolchain")

    plan, = tree["testNodes"]
    bundle, = plan["children"]
    require(plan["nodeType"] == "Test Plan" and bundle["nodeType"] == "UI test bundle"
            and bundle["name"] == "BeidUITests" and plan["result"] == bundle["result"] == summary["result"] == "Failed",
            "unexpected result hierarchy")
    for suite in bundle["children"]:
        require(suite["nodeType"] == "Test Suite" and suite["children"] and all(
            n["nodeType"] == "Test Case" for n in suite["children"]), "unattributed result in test tree")
        failed = any(n["result"] == "Failed" for n in suite["children"])
        require((suite["result"] == "Failed") == failed and suite["result"] in {"Passed", "Skipped", "Failed"},
                "inconsistent suite verdict")
    cases = result_case_nodes(tree)
    require(Counter(c for c, _, _ in cases) == Counter(selected), "missing, extra or duplicate case")
    counts = Counter(status for _, status, _ in cases)
    require(set(counts) <= {"Passed", "Failed", "Skipped"} and counts["Failed"] > 0, "unexpected case status")
    require({c for c, s, _ in cases if s == "Skipped"} == set(selected).intersection(skips), "expected skip mismatch")
    require(type(summary["totalTestCount"]) is int and summary["totalTestCount"] == len(cases), "total test count mismatch")
    for key, count in (("passedTests", counts["Passed"]), ("failedTests", counts["Failed"]),
                       ("skippedTests", counts["Skipped"]), ("expectedFailures", 0)):
        require(all(type(src[key]) is int and src[key] == count for src in (summary, config)), "result counts disagree")
    report["failed_cases"] = sorted(c for c, s, _ in cases if s == "Failed")

    messages = {}
    for case, status, node in cases:
        children = node.get("children", [])
        require(isinstance(children, list), "malformed case details")
        allowed = {"Passed": {"Runtime Warning"}, "Skipped": {"Skip Message", "Runtime Warning"},
                   "Failed": {"Failure Message", "Runtime Warning"}}[status]
        require(all(n["nodeType"] in allowed and not n.get("children") for n in children), "unattributed case evidence")
        if status == "Failed":
            message, = [n["name"] for n in children if n["nodeType"] == "Failure Message"]
            messages[case] = message
    rows = summary["testFailures"]
    require(isinstance(rows, list) and len(rows) == len(messages), "failure count mismatch")
    observed = {}
    for row in rows:
        identifier = row["targetName"] + "/" + row["testIdentifierString"].removesuffix("()")
        require(row["testIdentifierURL"] == "test://com.apple.xcode/Beid/" + identifier
                and row["testName"] == row["testIdentifierString"].split("/")[-1], "failure identifier mismatch")
        require(identifier not in observed, "duplicate failure summary")
        observed[identifier] = row["failureText"]
    require(observed == messages, "summary and tree disagree on failures")
    shard_root = f'/Users/runner/work/_temp/beid-{report["run_id"]}-{report["attempt"]}-{report["lane"]}'
    codes = {failure_code(message, shard_root) for message in messages.values()}
    require(len(codes) == 1, "mixed lifecycle failures")
    return codes.pop()


def classify(root):
    report = {"disposition": "ordinary_failure", "original_verdict": "unknown", "report_only": True}
    try:
        job = json.loads((root / "job.json").read_bytes())
        report["original_verdict"] = job["conclusion"]
        log = (root / "job.log").read_text(encoding="utf-8-sig")
        times = inspect_job(job, log, report)
        suffix = f'{report["attempt"]}-{report["lane"]}'
        report["structured_artifact"] = artifact(root, "structured", job, "ios-evidence-"+suffix)
        report["xcresult_artifact"] = artifact(root, "bundle", job, "ios-xcresult-"+suffix)
        verify_result_bundle(root / "bundle.zip")
        with zipfile.ZipFile(root / "structured.zip") as z:
            require(len(set(z.namelist())) == len(z.namelist()), "duplicate evidence files")
            require(all(z.getinfo(n).file_size <= 16 * 1024**2 for n in
                        ("manifest.json", "test-summary.json", "test-tree.json")), "structured evidence oversized")
            raw = z.read("manifest.json")
            report["manifest_sha256"] = hashlib.sha256(raw).hexdigest()
            reason = inspect_results(json.loads(raw), json.loads(z.read("test-summary.json")),
                                     json.loads(z.read("test-tree.json")), report, times)
        require(all(value in log for value in (report["head"], report["simulator"]["deviceId"],
                                            report["simulator"]["deviceName"])), "job log identity mismatch")
        report.update(disposition="comparison_candidate", reason=reason)
    except (OSError, ValueError, ExpatError, KeyError, IndexError, TypeError, AttributeError, EOFError, OverflowError, zlib.error, tarfile.TarError, plistlib.InvalidFileException, zipfile.BadZipFile) as exc:
        report["reason"] = str(exc)
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    print(json.dumps(classify(parser.parse_args().evidence), ensure_ascii=True, indent=2))
