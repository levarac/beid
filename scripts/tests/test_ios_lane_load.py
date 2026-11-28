from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from scripts import ios_lane_load
from scripts.tests.workflow_yaml import workflow_data


def recorded(root):
    output = io.StringIO()
    with redirect_stdout(output):
        ios_lane_load.finish(root)
    return output.getvalue()


class IOSLaneLoadTests(unittest.TestCase):
    def test_only_the_interval_row_has_lane_cpu_and_disk_load(self):
        output = ("disk0 disk12 cpu\nKB/t tps MB/s KB/t tps MB/s us sy id\n"
                  "12.8 50 3.1 0.0 0 0.0 21 9 70\n"
                  "10.2 16 1.4 6.1 4 0.3 7 3 90\n")
        self.assertEqual(ios_lane_load.interval_io(output), {
            "cpu_user_pct": 7, "cpu_system_pct": 3, "cpu_idle_pct": 90,
            "disk0_tps": 16, "disk0_MB_s": 1.4, "disk12_tps": 4, "disk12_MB_s": 0.3,
        })
        self.assertEqual(ios_lane_load.interval_io(output.rsplit("\n", 2)[0]), {})

    def test_unavailable_probes_do_not_fabricate_zero_load(self):
        with tempfile.TemporaryDirectory() as root, patch.object(ios_lane_load, "probe", return_value=""):
            sample = ios_lane_load.sample(Path(root))
        self.assertGreater(sample["disk_free_bytes"], 0)
        self.assertIn("utc_ms", sample)
        self.assertIn("monotonic_s", sample)
        self.assertNotIn("cpu_idle_pct", sample)
        self.assertNotIn("pressure_level", sample)
        self.assertNotIn("pageouts", sample)

    def test_public_log_contains_only_numeric_metrics_from_complete_rows(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            row = {"utc_ms": 42, "disk0_MB_s": 1.2, "pressure_level": "private-value", "/private/path": 3}
            (root / "ui-load.live").write_text('invalid\n[]\n' + json.dumps(row) + '\n{"utc_ms":')
            lines = recorded(root).splitlines()
            self.assertTrue((root / "ui-load.stop").exists())
            self.assertEqual(len(lines), 3)
            self.assertEqual(lines[1], 'BEID_UI_LOAD {"utc_ms":42,"disk0_MB_s":1.2}')
            self.assertEqual(lines[2], 'BEID_UI_LOAD {"samples":1}')

    def test_log_budget_includes_prefixes_and_newlines(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "ui-load.live").write_bytes(b'{"utc_ms":1}\n' * 1000)
            with patch.object(ios_lane_load, "MAX_BYTES", 1024):
                output = recorded(root)
            self.assertLessEqual(len(output.encode()), 1024)
            self.assertGreater(len(output.splitlines()), 2)

    def test_observer_failure_is_isolated_from_the_workflow(self):
        path = Path(__file__).resolve().parents[2] / ".github/workflows/pr-ci-ios-macos.yml"
        steps = workflow_data(path.read_text())["jobs"]["tests"]["steps"]
        names = [step.get("name") for step in steps]
        start = names.index("Start UI lane load sampling")
        finish = names.index("Record UI lane load samples")
        self.assertLess(start, names.index("Create shard-owned simulator"))
        self.assertGreater(finish, names.index("Delete shard-owned simulator"))
        self.assertIn("!cancelled()", steps[finish]["if"])
        # Missing collector and an invalid destination: both steps still exit zero.
        with tempfile.TemporaryDirectory() as temp:
            for i in (start, finish):
                self.assertIn("startsWith(matrix.lane, 'ui-')", steps[i]["if"])
                result = subprocess.run(["/bin/bash", "-eo", "pipefail", "-c", steps[i]["run"]],
                                        cwd=temp, env={"PATH": temp, "CI_OUTPUT_ROOT": temp + "/absent"},
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stderr, "")
            self.assertEqual(result.stdout.strip(), 'BEID_UI_LOAD {"sampling_error":1}')
