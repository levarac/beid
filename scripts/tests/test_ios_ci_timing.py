"""Exercise timing with child processes, without Xcode or a simulator."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class TimingTest(unittest.TestCase):
    def run_child(self, folder, code, phase="build"):
        return subprocess.run([
            sys.executable, "-m", "scripts.ios_ci_timing", "--phase", phase,
            "--log", str(folder / "build.log"), "--timings", str(folder / "timings.jsonl"),
            "--", sys.executable, "-c", code,
        ], cwd=ROOT, capture_output=True, text=True)

    def test_phase_timestamps_and_raw_compile_timings_are_retained(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            result = self.run_child(folder,
                "print('PhaseScriptExecution Build\\\\ BeidSharedKit /tmp/script.sh');"
                "print('BUILD SUCCESSFUL in 3s');"
                "print('SwiftCompile normal arm64 Beid.swift');"
                "print('CompileSwiftSources (2.0 seconds)')")
            self.assertEqual(result.returncode, 0, result.stderr)
            events = [json.loads(line) for line in (folder / "timings.jsonl").read_text().splitlines()]
            self.assertEqual([(e["phase"], e["event"]) for e in events], [
                ("build", "start"), ("kmp", "start"), ("kmp", "end"),
                ("swift-compile-window", "start"), ("swift-compile-window", "end"),
                ("build", "end"),
            ])
            self.assertTrue(all(e["utc"].endswith("+00:00") for e in events))
            self.assertIn("CompileSwiftSources (2.0 seconds)", (folder / "build.log").read_text())

    def test_restored_export_finishes_kmp_before_swift_compilation(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            output = "\n".join([
                "Restored Kotlin Swift Export",
                "PhaseScriptExecution Build BeidSharedKit /tmp/script.sh",
                "Restored Kotlin Swift Export",
                "SwiftCompile normal arm64 Beid.swift",
            ])
            result = self.run_child(folder, f"print({output!r})")
            self.assertEqual(result.returncode, 0, result.stderr)
            events = [json.loads(line) for line in (folder / "timings.jsonl").read_text().splitlines()]
            kmp = [event for event in events if event["phase"] == "kmp"]
            self.assertEqual([event["event"] for event in kmp], ["start", "end"])
            self.assertTrue(kmp[1]["restored"])
            self.assertGreaterEqual(kmp[1]["elapsed_seconds"], 0)
            swift_start = next(event for event in events if event["phase"] == "swift-compile-window")
            self.assertLess(events.index(kmp[1]), events.index(swift_start))

    def test_failure_preserves_exit_log_and_incomplete_phase(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            result = self.run_child(folder,
                "print('PhaseScriptExecution Build\\\\ BeidSharedKit /tmp/script.sh');"
                "print('error: compile failed');raise SystemExit(65)")
            self.assertEqual(result.returncode, 65)
            self.assertIn("error: compile failed", result.stdout)
            events = [json.loads(line) for line in (folder / "timings.jsonl").read_text().splitlines()]
            self.assertEqual(events[-1]["exit_code"], 65)
            self.assertIn({"phase": "kmp", "event": "incomplete"},
                          [{"phase": e["phase"], "event": e["event"]} for e in events])

    def test_spm_is_timed_separately(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            self.assertEqual(self.run_child(folder, "print('resolved')", "spm").returncode, 0)
            events = [json.loads(line) for line in (folder / "timings.jsonl").read_text().splitlines()]
            self.assertEqual([(e["phase"], e["event"]) for e in events],
                             [("spm", "start"), ("spm", "end")])
