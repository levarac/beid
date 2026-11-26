import copy
import hashlib
import io
import json
from pathlib import Path
import plistlib
import tarfile
import tempfile
import unittest
import zipfile

from scripts.ios_lifecycle_report import TEST_STEP, VERIFY_STEP, classify, inspect_results


LANE = "ui-1"
SHA = "c" * 40
ROOT = "/Users/runner/work/_temp/beid-10-1-ui-1"
TERM = "Failed to terminate org.levarac.beid:123: Failed to terminate org.levarac.beid:0"
LAUNCH = (f"Failed to launch <XCUIApplicationImpl: 0xab12 org.levarac.beid at {ROOT}"
          "/DerivedData/Build/Products/Debug-iphonesimulator/Beid.app> via Xcode: "
          "Timed out while launching application via Xcode.")
CASES = ["BeidUITests/S/test" + n for n in ("A", "B", "C", "Other")]


def failure(case, text):
    ident = case.removeprefix("BeidUITests/") + "()"
    return {"targetName": "BeidUITests", "testIdentifierString": ident, "testIdentifierURL":
            "test://com.apple.xcode/Beid/" + case, "testName": ident.split("/")[-1], "failureText": text}


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.report = {"run_id": 10, "attempt": 1, "lane": LANE, "head": SHA}
        self.manifest = {"mode": "full", "sha": SHA, "arch": "arm64", "xcode": "Xcode 27.2", "sdk": "27.2",
                         "unit": ["BeidTests/U/testA"], "ui": CASES, "iphone_skips": [CASES[1]],
                         "shards": [CASES[:3], CASES[3:]]}
        dev = {"deviceName": "ci-beid-10-1-tests-ui-1-test", "platform": "iOS Simulator", "deviceId": "UDID",
               "modelName": "iPhone 18 Pro", "osVersion": "27.0", "architecture": "arm64"}
        config = {"configurationName": "Test Scheme Action", "configurationId": "1"}
        counts = {"passedTests": 1, "skippedTests": 1, "failedTests": 1, "expectedFailures": 0}
        self.summary = {**counts, "totalTestCount": 3, "result": "Failed", "startTime": 2, "finishTime": 8,
                        "devicesAndConfigurations": [{**counts, "device": dev, "testPlanConfiguration": config}],
                        "testFailures": [failure(CASES[0], TERM)]}
        self.nodes = [{"nodeIdentifier": case.split("/", 1)[1]+"()", "nodeType": "Test Case", "result": result,
                       "children": children} for case, result, children in zip(CASES, ["Failed", "Skipped", "Passed"],
                       [[{"nodeType": "Failure Message", "name": TERM}], [{"nodeType": "Skip Message", "name": "Skip"}], []])]
        suite = {"nodeType": "Test Suite", "result": "Failed", "name": "S", "children": self.nodes}
        bundle = {"nodeType": "UI test bundle", "name": "BeidUITests", "result": "Failed", "children": [suite]}
        self.tree = {"devices": [dev], "testPlanConfigurations": [config], "testNodes": [
            {"nodeType": "Test Plan", "result": "Failed", "children": [bundle]}]}

    def inspect(self):
        return inspect_results(self.manifest, self.summary, self.tree, self.report, (0, 12))

    def test_exact_messages(self):
        for message, code in [(TERM, "app_termination_failed"), (LAUNCH, "app_launch_timeout")]:
            self.summary["testFailures"][0]["failureText"] = self.nodes[0]["children"][0]["name"] = message
            self.assertEqual(self.inspect(), code)

    def test_similar_or_appended_text_never_matches(self):
        for message in (TERM.replace("beid", "other"), TERM + "\nassertion failed", LAUNCH.replace("ui-1", "ui-2"),
                        "Failed to get matching snapshots: Timed out while evaluating UI query.", "XCTAssertTrue failed"):
            with self.subTest(message=message):
                self.summary["testFailures"][0]["failureText"] = self.nodes[0]["children"][0]["name"] = message
                with self.assertRaisesRegex(ValueError, "unrecognized"):
                    self.inspect()

    def test_mixed_failures(self):
        self.nodes[2].update(result="Failed", children=[{"nodeType": "Failure Message", "name": LAUNCH}])
        self.summary["testFailures"].append(failure(CASES[2], LAUNCH))
        for src in (self.summary, self.summary["devicesAndConfigurations"][0]):
            src.update(passedTests=0, failedTests=2)
        with self.assertRaisesRegex(ValueError, "mixed"):
            self.inspect()

    def test_ledger_and_provenance(self):
        for key, value in [("sha", "different"), ("mode", "smoke"), ("iphone_skips", []),
                           ("shards", [CASES[:2], CASES[2:]]), ("shards", [CASES[:3], CASES[2:]])]:
            with self.subTest(field=key):
                with self.assertRaises(ValueError):
                    inspect_results({**self.manifest, key: value}, self.summary, self.tree, self.report, (0, 12))
        self.nodes.append(copy.deepcopy(self.nodes[0]))
        with self.assertRaisesRegex(ValueError, "duplicate"):
            self.inspect()

    def test_incomplete_inconsistent_and_extra_evidence(self):
        for key, value in [("totalTestCount", 4), ("failedTests", True), ("testFailures", []),
                           ("testFailures", [failure(CASES[0], LAUNCH)]), ("finishTime", 13)]:
            with self.subTest(field=key):
                with self.assertRaises(ValueError):
                    inspect_results(self.manifest, {**self.summary, key: value}, self.tree, self.report, (0, 12))
        self.nodes[0]["children"].append({"nodeType": "Failure Message", "name": "assertion failed"})
        with self.assertRaises(ValueError):
            self.inspect()

    def save_fixture(self, root):
        start = "1970-01-01T00:00:00Z"
        end = "1970-01-01T00:00:12Z"
        steps = ["Validate and restore test products", "Create shard-owned simulator", "Boot shard-owned simulator",
                 TEST_STEP, VERIFY_STEP, "Upload shard test evidence", "Archive failed UI test result",
                 "Upload failed UI test result", "Delete shard-owned simulator"]
        job = {"name": "iOS full tests (ui-1)", "status": "completed", "conclusion": "failure",
               "id": 12, "head_sha": SHA, "run_id": 10, "run_attempt": 1, "runner_name": "Runner", "runner_group_name": "GitHub Actions",
               "labels": ["xcode-27"], "started_at": start, "completed_at": end, "steps": [
                   {"name": name, "conclusion": "failure" if name in (TEST_STEP, VERIFY_STEP) else "success",
                    "started_at": start, "completed_at": end} for name in steps]}
        (root/"job.json").write_text(json.dumps(job))
        (root/"job.log").write_text(f"{start} ##[group]Runner Image\n{start} Image: xcode-27-arm64\n"
                                   f"{start} Version: 1\n{end} ##[error]Process completed with exit code 65.\n"
                                   f"{start} {SHA} ci-beid-10-1-tests-ui-1-test UDID\n")
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w:gz") as tar:
            for name, contents in [("Info.plist", plistlib.dumps({"rootId": {"hash": "id"}})),
                                   ("Data/data.id", b"a"), ("Data/refs.id", b"b")]:
                item = tarfile.TarInfo("Tests.xcresult/"+name)
                item.size = len(contents)
                tar.addfile(item, io.BytesIO(contents))
        for kind, prefix, contents in [
            ("structured", "evidence", {"manifest.json": json.dumps(self.manifest),
             "test-tree.json": json.dumps(self.tree), "test-summary.json": json.dumps(self.summary)}),
            ("bundle", "xcresult", {"Tests.xcresult.tar.gz": buf.getvalue()})]:
            archive = root/(kind+".zip")
            with zipfile.ZipFile(archive, "w") as z:
                for name, data in contents.items():
                    z.writestr(name, data)
            (root/(kind+".json")).write_text(json.dumps({"id": 123, "name": f"ios-{prefix}-1-ui-1",
                "size_in_bytes": archive.stat().st_size, "digest": "sha256:"+hashlib.sha256(archive.read_bytes()).hexdigest(),
                "workflow_run": {"head_sha": SHA, "id": 10}}))
        return job

    def test_corrupt_or_wrong_attempt_receipts(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.save_fixture(root)
            bundle = root / "bundle.zip"
            original = bundle.read_bytes()
            bundle.write_bytes(original[:-1] + bytes([original[-1] ^ 1]))
            self.assertEqual(classify(root)["reason"], "artifact digest mismatch")
            bundle.write_bytes(original)
            meta = root / "bundle.json"
            info = json.loads(meta.read_text())
            meta.write_text(json.dumps({**info, "name": "ios-xcresult-2-ui-1"}))
            self.assertEqual(classify(root)["reason"], "artifact identity mismatch")
            meta.write_text(json.dumps(info))
            with zipfile.ZipFile(bundle, "w") as z:
                z.writestr("Tests.xcresult.tar.gz", b"broken compressed bundle")
            info.update(size_in_bytes=bundle.stat().st_size,
                        digest="sha256:" + hashlib.sha256(bundle.read_bytes()).hexdigest())
            meta.write_text(json.dumps(info))
            self.assertEqual(classify(root)["disposition"], "ordinary_failure")

    def test_infrastructure_error_alongside_xctest_exit(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.save_fixture(root)
            with (root / "job.log").open("a") as log:
                log.write("1970-01-01T00:00:11Z ##[error]The operation was canceled.\n")
            self.assertEqual(classify(root)["disposition"], "ordinary_failure")

    def test_archive_binding_and_job_outcomes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            job = self.save_fixture(root)
            report = classify(root)
            self.assertEqual((report["disposition"], report["original_verdict"]), ("comparison_candidate", "failure"))
            for result in ("cancelled", "timed_out", "success"):
                (root/"job.json").write_text(json.dumps({**job, "conclusion": result}))
                self.assertEqual(classify(root)["disposition"], "ordinary_failure")
            (root/"job.json").write_text(json.dumps(job))
            (root/"job.log").write_text("##[error]The operation was canceled.")
            self.assertEqual(classify(root)["disposition"], "ordinary_failure")
            self.save_fixture(root)
            (root/"bundle.zip").write_bytes(b"partial")
            self.assertEqual(classify(root)["reason"], "artifact size mismatch")
            (root/"bundle.zip").unlink()
            self.assertEqual(classify(root)["disposition"], "ordinary_failure")
