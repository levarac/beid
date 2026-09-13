from __future__ import annotations

import contextlib
import argparse
import importlib.util
import io
import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "run_local_tests.py"
FIXTURES = Path(__file__).with_name("fixtures")

def load_module():
    if not SCRIPT.exists():
        raise AssertionError(f"production CLI is missing: {SCRIPT}")
    spec = importlib.util.spec_from_file_location("run_local_tests", SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module

class ModuleTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls): cls.tool = load_module()

class ChildTests(ModuleTest):
    def test_real_fake_child_preserves_exit_and_raw_streams(self):
        for exit_code in (0, 19):
            with self.subTest(exit_code=exit_code), tempfile.TemporaryDirectory() as tmp:
                log = Path(tmp) / "raw.log"
                with contextlib.redirect_stdout(io.StringIO()):
                    result = self.tool.run_primary_child(
                        [sys.executable, str(FIXTURES / "fake_child.py"), str(exit_code)],
                        ROOT, log, {},
                    )
                self.assertEqual(result.returncode, exit_code)
                self.assertIn("fake stdout", log.read_text())
                self.assertIn("fake stderr", log.read_text())

    def test_path_precedes_launch_success_noise_suppressed_and_raw_log_complete(self):
        with tempfile.TemporaryDirectory() as tmp:
            log=Path(tmp)/"raw.log"; stdout=io.StringIO(); seen=[]
            def launch(*args,**kwargs):
                seen.append(stdout.getvalue()); return subprocess.CompletedProcess(args[0],0,"compile noise\nTest Case passed\n","link noise\n")
            with contextlib.redirect_stdout(stdout): result=self.tool.run_primary_child(["fake"],Path(tmp),log,{},launcher=launch)
            self.assertEqual(result.returncode,0); self.assertIn(str(log.resolve()),seen[0]); self.assertNotIn("compile noise",stdout.getvalue()); self.assertEqual(log.read_text(),"compile noise\nTest Case passed\nlink noise\n")

    def test_failure_expands_complete_raw_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            log=Path(tmp)/"raw.log"; stdout=io.StringIO(); launch=mock.Mock(return_value=subprocess.CompletedProcess([],9,"out\n","stack\n"))
            with contextlib.redirect_stdout(stdout):
                result=self.tool.run_primary_child(["fake"],Path(tmp),log,{},launcher=launch); self.tool.print_raw_log_on_failure(result.returncode,log)
            self.assertEqual(result.returncode,9); self.assertIn("out\nstack",stdout.getvalue())

    def test_exact_exit_signal_and_launch_error_mapping(self):
        self.assertEqual(self.tool.shell_exit_code(0),0); self.assertEqual(self.tool.shell_exit_code(37),37); self.assertEqual(self.tool.shell_exit_code(-signal.SIGTERM),128+signal.SIGTERM)
        self.assertEqual(self.tool.launch_error_code(FileNotFoundError()),127); self.assertEqual(self.tool.launch_error_code(PermissionError()),126)

class AndroidTests(ModuleTest):
    def test_ansi_task_outcomes_all_required_states(self):
        log="\n".join(["\x1b[32m> Task :shared:testAndroidHostTest\x1b[0m","> Task :app:testDebugUnitTest UP-TO-DATE","> Task :cached:testThing FROM-CACHE","> Task :empty:testThing NO-SOURCE","> Task :broken:testThing FAILED"])
        self.assertEqual(self.tool.parse_gradle_task_outcomes(log),{":shared:testAndroidHostTest":"EXECUTED",":app:testDebugUnitTest":"UP-TO-DATE",":cached:testThing":"FROM-CACHE",":empty:testThing":"NO-SOURCE",":broken:testThing":"FAILED"})

    def test_junit_leaf_counts_duplicates_fail_error_skip_and_details(self):
        result=self.tool.parse_junit_files([FIXTURES/"android-results.xml"])
        self.assertEqual((result.total,result.passed,result.failed,result.skipped),(4,1,2,1)); self.assertEqual(len(result.failures),2); self.assertIn("assertion stack",result.failures[0].details); self.assertIn("exception stack",result.failures[1].details)

    def test_junit_testsuite_root(self):
        result=self.tool.parse_junit_files([FIXTURES/"android-testsuite-root.xml"]); self.assertEqual((result.total,result.passed,result.failed,result.skipped),(1,1,0,0))

    def test_missing_and_malformed_xml_warn(self):
        with tempfile.TemporaryDirectory() as tmp:
            bad=Path(tmp)/"bad.xml"; bad.write_text("<testsuite>"); result=self.tool.parse_junit_files([bad,Path(tmp)/"missing.xml"])
        self.assertEqual(result.total,0); self.assertEqual(len(result.warnings),2); self.assertTrue(all("EVIDENCE WARNING" in x for x in result.warnings))

    def test_fresh_xml_rejects_stale(self):
        with tempfile.TemporaryDirectory() as tmp:
            old=Path(tmp)/"old.xml"; changed=Path(tmp)/"changed.xml"; new=Path(tmp)/"new.xml"; old.write_text("<testsuite/>"); changed.write_text("<testsuite/>"); before=self.tool.snapshot_xml([old,changed]); time.sleep(.002); changed.write_text("<testsuite><testcase name='now'/></testsuite>"); new.write_text("<testsuite/>"); fresh,stale=self.tool.select_fresh_xml([old,changed,new],before)
        self.assertEqual(set(fresh),{changed,new}); self.assertEqual(stale,[old])

    def test_no_source_warning_zero_never_green_and_build_no_fake_count(self):
        no_source=self.tool.format_android_task_summary(":shared:testAndroidHostTest","NO-SOURCE",None); self.assertIn("EVIDENCE WARNING",no_source); self.assertIn("0 tests",no_source); self.assertNotIn("GREEN",no_source)
        build=self.tool.format_android_task_summary(":app:assembleDebug","EXECUTED",None); self.assertIn("EXECUTED",build); self.assertNotIn("tests",build)

    def test_android_command_contract_and_fully_qualified_validation(self):
        argv,cwd,env=self.tool.android_command(ROOT,[":shared:testAndroidHostTest",":app:testDebugUnitTest"],"/jdk"); self.assertEqual(cwd,ROOT/"android"); self.assertEqual(env["JAVA_HOME"],"/jdk"); self.assertIn("--console=plain",argv); self.assertIn("--stacktrace",argv)
        with self.assertRaises(ValueError): self.tool.validate_gradle_tasks(["testDebugUnitTest"])

    def test_junit_directory_respects_external_shared_project_directory(self):
        self.assertEqual(
            self.tool.junit_directory(ROOT, ":shared:testAndroidHostTest"),
            ROOT / "shared/build/test-results/testAndroidHostTest",
        )
        self.assertEqual(
            self.tool.junit_directory(ROOT, ":app:testDebugUnitTest"),
            ROOT / "android/app/build/test-results/testDebugUnitTest",
        )

class IOSTests(ModuleTest):
    def test_concrete_udid_and_mandatory_mutually_exclusive_state_choice(self):
        parser=self.tool.build_parser(); invalid=[["ios","--udid","iPhone 17","--erase-simulator"],["ios","--udid","00000000-0000-0000-0000-000000000000"],["ios","--udid","00000000-0000-0000-0000-000000000000","--erase-simulator","--keep-simulator-state"]]
        for argv in invalid:
            with self.subTest(argv=argv), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit): self.tool.parse_args(parser,argv)

    def test_exact_destination_bundle_and_focus_argv(self):
        bundle=Path("/tmp/unique.xcresult"); argv=self.tool.ios_command(ROOT,"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",bundle,"test-without-building",["BeidTests/WalletTests/testOne"]); self.assertIn("platform=iOS Simulator,id=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",argv); self.assertEqual(argv[argv.index("-resultBundlePath")+1],str(bundle)); self.assertIn("-only-testing:BeidTests/WalletTests/testOne",argv); self.assertEqual(argv[-1],"test-without-building")

    def test_erase_sequence_and_actual_state(self):
        responses=[subprocess.CompletedProcess([],0,"","") for _ in range(4)]+[subprocess.CompletedProcess([],0,json.dumps({"devices":{"r":[{"udid":"A","state":"Booted"}]}}),"")]; runner=mock.Mock(side_effect=responses); evidence=self.tool.prepare_simulator("A",True,runner=runner); self.assertTrue(evidence.erased); self.assertEqual(evidence.state,"Booted"); self.assertEqual([x.args[0][2] for x in runner.call_args_list[:4]],["shutdown","erase","boot","bootstatus"])

    def test_keep_does_not_erase_and_reports_state(self):
        runner=mock.Mock(return_value=subprocess.CompletedProcess([],0,json.dumps({"devices":{"r":[{"udid":"A","state":"Shutdown"}]}}),"")); evidence=self.tool.prepare_simulator("A",False,runner=runner); self.assertFalse(evidence.erased); self.assertEqual(evidence.state,"Shutdown"); self.assertEqual(runner.call_count,1)

    def test_bundle_tree_counts_test_case_leaves_and_failure_details(self):
        parsed=self.tool.parse_xcresult_tests(json.loads((FIXTURES/"ios-tests.json").read_text())); self.assertEqual((parsed.total,parsed.passed,parsed.failed,parsed.skipped),(3,1,1,1)); self.assertEqual(parsed.bundles["BeidTests"].total,3); self.assertIn("full structured failure detail",parsed.failures[0].details)

    def test_summary_consistency_zero_missing_malformed_and_failure_text(self):
        summary=json.loads((FIXTURES/"ios-summary.json").read_text()); parsed=self.tool.parse_xcresult_tests(json.loads((FIXTURES/"ios-tests.json").read_text())); self.assertEqual(self.tool.validate_xcresult_summary(summary,parsed),[]); zero=dict(summary,totalTestCount=0,passedTests=0,failedTests=0,skippedTests=0); self.assertTrue(any("EVIDENCE WARNING" in x for x in self.tool.validate_xcresult_summary(zero,parsed)))
        for payload in (None,"{bad"): self.assertTrue(any("EVIDENCE WARNING" in x for x in self.tool.parse_json_evidence(payload,"xcresult summary")[1]))
        self.assertIn("XCTAssertEqual",self.tool.summary_failures(summary)[0].details)

class MainTests(ModuleTest):
    def test_parser_warning_never_replaces_nonzero_or_zero_child_rc(self):
        for child_rc in (0,23):
            with self.subTest(child_rc=child_rc),mock.patch.object(self.tool,"run_android",return_value=(child_rc,["EVIDENCE WARNING: bad XML"])), contextlib.redirect_stdout(io.StringIO()): self.assertEqual(self.tool.main(["android",":app:testDebugUnitTest"]),child_rc)

    def test_evidence_exception_becomes_warning_without_replacing_child_rc(self):
        def broken_parser():
            raise ValueError("malformed fixture")
        value, warnings = self.tool.guard_evidence(41, "JUnit parser", broken_parser)
        self.assertIsNone(value)
        self.assertEqual(self.tool.shell_exit_code(41), 41)
        self.assertIn("EVIDENCE WARNING", warnings[0])


class CommandPathTests(ModuleTest):
    def android_args(self, task=":app:testDebugUnitTest"):
        return argparse.Namespace(tasks=[task])

    def ios_args(self, *, erase=True):
        return argparse.Namespace(
            udid="AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            erase_simulator=erase,
            action="test",
            configuration="Debug",
            only_testing=[],
        )

    def run_android_fixture(self, child_rc, child_log, junit_xml=None):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "android").mkdir()

            def child(_argv, _cwd, raw_log, _env, **_kwargs):
                raw_log.write_text(child_log)
                if junit_xml is not None:
                    result_dir = root / "android/app/build/test-results/testDebugUnitTest"
                    result_dir.mkdir(parents=True)
                    (result_dir / "TEST-fixture.xml").write_text(junit_xml)
                return self.tool.ChildResult(child_rc)

            output = io.StringIO()
            with (
                mock.patch.object(self.tool, "REPO_ROOT", root),
                mock.patch.object(self.tool, "resolve_java_home", return_value="/jdk"),
                mock.patch.object(self.tool, "run_primary_child", side_effect=child),
                contextlib.redirect_stdout(output),
            ):
                result = self.tool.run_android(self.android_args())
            run_dirs = list((root / "build/local-test-runs").iterdir())
            self.assertEqual(len(run_dirs), 1)
            raw_log = run_dirs[0] / "raw.log"
            return result, output.getvalue(), raw_log, raw_log.read_text()

    def test_android_success_is_quiet_but_reports_task_counts_and_raw_path(self):
        result, output, raw_log, raw_text = self.run_android_fixture(
            0,
            "> Task :app:testDebugUnitTest\ncompile noise\nTest Case passed\n",
            "<testsuite><testcase name='one'/><testcase name='two'><skipped/></testcase></testsuite>",
        )
        self.assertEqual(result, (0, []))
        self.assertIn(":app:testDebugUnitTest: EXECUTED — total=2 pass=1 fail=0 skip=1", output)
        self.assertIn("Android aggregate: total=2 pass=1 fail=0 skip=1", output)
        self.assertIn(f"Raw log: {raw_log.resolve()}", output)
        self.assertNotIn("compile noise", output)
        self.assertIn("compile noise", raw_text)

    def test_android_no_source_stays_exit_zero_but_is_never_silent(self):
        result, output, raw_log, raw_text = self.run_android_fixture(
            0,
            "> Task :app:testDebugUnitTest NO-SOURCE\nBUILD SUCCESSFUL\n",
        )
        self.assertEqual(result[0], 0)
        self.assertTrue(any("NO-SOURCE" in item for item in result[1]))
        self.assertIn("NO-SOURCE", output)
        self.assertIn("EVIDENCE WARNING", output)
        self.assertIn("total=0 pass=0 fail=0 skip=0", output)
        self.assertIn("BUILD SUCCESSFUL", raw_text)

    def test_android_failure_prints_complete_raw_log_and_preserves_exit(self):
        result, output, raw_log, _raw_text = self.run_android_fixture(
            23,
            "> Task :app:testDebugUnitTest FAILED\nAssertionError: boom\nfull stack trace line\n",
            "<testsuite><testcase classname='Example' name='fails'><failure message='boom'>JUnit stack</failure></testcase></testsuite>",
        )
        self.assertEqual(result[0], 23)
        self.assertIn("AssertionError: boom", output)
        self.assertIn("full stack trace line", output)
        self.assertIn("JUnit stack", output)
        self.assertIn(str(raw_log.resolve()), output)

    def test_android_evidence_parser_error_does_not_hide_child_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "android").mkdir()

            def child(_argv, _cwd, raw_log, _env, **_kwargs):
                raw_log.write_text("original failure and stack\n")
                return self.tool.ChildResult(41)

            output = io.StringIO()
            with (
                mock.patch.object(self.tool, "REPO_ROOT", root),
                mock.patch.object(self.tool, "resolve_java_home", return_value="/jdk"),
                mock.patch.object(self.tool, "run_primary_child", side_effect=child),
                mock.patch.object(self.tool, "parse_gradle_task_outcomes", side_effect=ValueError("bad task log")),
                contextlib.redirect_stdout(output),
            ):
                result = self.tool.run_android(self.android_args())
        self.assertEqual(result[0], 41)
        self.assertTrue(any("bad task log" in item for item in result[1]))
        self.assertIn("original failure and stack", output.getvalue())

    def test_android_prelaunch_failure_still_materializes_raw_log(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            output = io.StringIO()
            with (
                mock.patch.object(self.tool, "REPO_ROOT", root),
                mock.patch.object(
                    self.tool,
                    "resolve_java_home",
                    side_effect=RuntimeError("no supported JDK"),
                ),
                contextlib.redirect_stdout(output),
            ):
                result = self.tool.run_android(self.android_args())
            raw_logs = list((root / "build/local-test-runs").glob("*/raw.log"))
            self.assertEqual(len(raw_logs), 1)
            self.assertTrue(raw_logs[0].is_file())
        self.assertEqual(result[0], 126)
        self.assertIn(str(raw_logs[0].resolve()), output.getvalue())

    def run_ios_fixture(self, child_rc, summary, tests, *, erase=True):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "ios").mkdir()

            def child(_argv, _cwd, raw_log, _env, **_kwargs):
                raw_log.write_text("xcode internal noise\nTest failure stack from xcode\n")
                raw_log.parent.joinpath("result.xcresult").mkdir()
                return self.tool.ChildResult(child_rc)

            def xcresult(_bundle, kind):
                payload = summary if kind == "summary" else tests
                return subprocess.CompletedProcess([], 0, json.dumps(payload), "")

            output = io.StringIO()
            simulator = self.tool.SimulatorEvidence(
                "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", "Booted", erase
            )
            patches = (
                mock.patch.object(self.tool, "REPO_ROOT", root),
                mock.patch.object(self.tool, "prepare_simulator", return_value=simulator),
                mock.patch.object(self.tool, "run_primary_child", side_effect=child),
                mock.patch.object(self.tool, "xcresult_json", side_effect=xcresult),
            )
            with patches[0], patches[1], patches[2], patches[3], contextlib.redirect_stdout(output):
                result = self.tool.run_ios(self.ios_args(erase=erase))
            run_dirs = list((root / "build/local-test-runs").iterdir())
            return result, output.getvalue(), run_dirs[0] / "raw.log"

    def test_ios_success_is_quiet_and_reports_one_simulator_evidence_line(self):
        tests = {
            "testNodes": [{
                "nodeType": "Unit test bundle",
                "name": "BeidTests",
                "children": [{"nodeType": "Test Case", "name": "testOne()", "result": "Passed"}],
            }]
        }
        summary = {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0}
        result, output, raw_log = self.run_ios_fixture(0, summary, tests)
        self.assertEqual(result, (0, []))
        self.assertIn(
            "Simulator: UDID=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE state=Booted erased=yes",
            output,
        )
        self.assertEqual(output.count("Simulator:"), 1)
        self.assertIn("iOS bundle BeidTests: total=1 pass=1 fail=0 skip=0", output)
        self.assertIn(f"Raw log: {raw_log.resolve()}", output)
        self.assertNotIn("xcode internal noise", output)

    def test_ios_failure_prints_complete_xcode_log_and_preserves_exit(self):
        summary = json.loads((FIXTURES / "ios-summary.json").read_text())
        tests = json.loads((FIXTURES / "ios-tests.json").read_text())
        with mock.patch.object(
            self.tool.subprocess,
            "run",
            return_value=subprocess.CompletedProcess([], 1, "", "details unavailable"),
        ):
            result, output, raw_log = self.run_ios_fixture(65, summary, tests, erase=False)
        self.assertEqual(result[0], 65)
        self.assertIn("Test failure stack from xcode", output)
        self.assertIn("full structured failure detail", output)
        self.assertIn("erased=no", output)
        self.assertIn(str(raw_log.resolve()), output)

    def test_ios_simulator_setup_failure_still_materializes_raw_log(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            output = io.StringIO()
            with (
                mock.patch.object(self.tool, "REPO_ROOT", root),
                mock.patch.object(
                    self.tool,
                    "prepare_simulator",
                    side_effect=RuntimeError("simulator unavailable"),
                ),
                contextlib.redirect_stdout(output),
            ):
                result = self.tool.run_ios(self.ios_args())
            raw_logs = list((root / "build/local-test-runs").glob("*/raw.log"))
            self.assertEqual(len(raw_logs), 1)
            self.assertTrue(raw_logs[0].is_file())
        self.assertEqual(result[0], 126)
        self.assertIn(str(raw_logs[0].resolve()), output.getvalue())

if __name__ == "__main__": unittest.main()
