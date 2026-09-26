"""CI creates its own device; existing simulators are never candidates."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
IPHONE = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
PREFERRED_IPHONE = "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"
FALLBACK_IPHONE = "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"
OWNED_UDID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"


def runtime(**overrides):
    return {
        "name": "iOS 26.5",
        "identifier": RUNTIME,
        "isAvailable": True,
        "supportedDeviceTypes": [{"identifier": IPHONE, "name": "iPhone 17 Pro"}],
        **overrides,
    }


class CiSimulatorTests(unittest.TestCase):
    def create(self, runtimes, *, create_exit=0, list_exit=0, delete_exit=0, udid=OWNED_UDID):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            fixture = folder / "runtimes.json"
            fixture.write_text(json.dumps({"runtimes": runtimes}))
            calls_path = folder / "calls.jsonl"
            fake = folder / "xcrun"
            fake.write_text(
                f"#!{sys.executable}\n"
                "import json, os, pathlib, sys\n"
                "args = sys.argv[1:]\n"
                "with open(os.environ['CALLS'], 'a') as calls:\n"
                "    calls.write(json.dumps(args) + '\\n')\n"
                "if args == ['simctl', 'list', 'runtimes', '--json']:\n"
                "    print(pathlib.Path(os.environ['FIXTURE']).read_text())\n"
                "    if os.environ['LIST_EXIT'] != '0': print('runtime service unavailable', file=sys.stderr)\n"
                "    sys.exit(int(os.environ['LIST_EXIT']))\n"
                "if args[:2] == ['simctl', 'create']:\n"
                "    if os.environ['CREATE_EXIT'] == '0':\n"
                "        print(os.environ['CREATED_UDID'])\n"
                "    else: print('device creation failed', file=sys.stderr)\n"
                "    sys.exit(int(os.environ['CREATE_EXIT']))\n"
                "if args[:2] == ['simctl', 'delete']:\n"
                "    if os.environ['DELETE_EXIT'] != '0': print('device deletion failed', file=sys.stderr)\n"
                "    sys.exit(int(os.environ['DELETE_EXIT']))\n"
                "sys.exit('unexpected simctl operation: ' + repr(args))\n"
            )
            fake.chmod(0o755)
            result = subprocess.run(
                [sys.executable, str(ROOT / "scripts/ci_simulator.py"),
                 "--name", "ci-beid-123-2-ios-simulator"],
                env={**os.environ, "PATH": str(folder) + os.pathsep + os.environ["PATH"],
                     "FIXTURE": str(fixture), "CALLS": str(calls_path),
                     "CREATE_EXIT": str(create_exit), "LIST_EXIT": str(list_exit),
                     "CREATED_UDID": udid, "DELETE_EXIT": str(delete_exit)},
                capture_output=True, text=True,
            )
            calls = [json.loads(line) for line in calls_path.read_text().splitlines()] if calls_path.exists() else []
            return result, calls

    def test_creates_new_device_without_reading_existing_devices(self):
        result, calls = self.create([runtime()])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), OWNED_UDID)
        self.assertEqual(calls[0], ["simctl", "list", "runtimes", "--json"])
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[1][:2], ["simctl", "create"])
        self.assertTrue(calls[1][2].startswith("ci-beid-123-2-ios-simulator-"))
        self.assertEqual(calls[1][3:], [IPHONE, RUNTIME])

    def test_repeated_runs_get_distinct_names(self):
        first, first_calls = self.create([runtime()])
        second, second_calls = self.create([runtime()])
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertNotEqual(first_calls[1][2], second_calls[1][2])

    def test_uses_explicit_preference_order_instead_of_alphabetical_order(self):
        types = [
            {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-11"},
            {"identifier": FALLBACK_IPHONE},
            {"identifier": IPHONE},
            {"identifier": PREFERRED_IPHONE},
        ]
        for available, expected in ((types, PREFERRED_IPHONE), (types[:-1], IPHONE),
                                    (types[:2], FALLBACK_IPHONE)):
            with self.subTest(expected=expected):
                result, calls = self.create([runtime(supportedDeviceTypes=available)])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(calls[-1][3:], [expected, RUNTIME])

    def test_selects_only_supported_iphone_identifier_in_exact_runtime(self):
        types = [
            {"name": "iPhone impostor", "identifier": "other.iPhone-17"},
            {"name": "iPhone", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro"},
            {"name": "iPhone 17 Pro Max", "identifier": IPHONE + "-Max"},
            {"name": "iPhone 17 Pro", "identifier": IPHONE},
        ]
        result, calls = self.create([
            runtime(name="iOS 26.4", identifier="wrong-runtime"),
            runtime(supportedDeviceTypes=types),
        ])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[-1][3:], [IPHONE, RUNTIME])

    def test_missing_or_unavailable_exact_runtime_fails_without_create(self):
        for runtimes in ([], [runtime(isAvailable=False)], [runtime(name="iOS 26.4")]):
            with self.subTest(runtimes=runtimes):
                result, calls = self.create(runtimes)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("no available iOS 26.5 runtime", result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertEqual(len(calls), 1)

    def test_no_supported_iphone_fails_without_fallback(self):
        for types in ([], [{"identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro"}],
                      [{"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-11"}],
                      [{"identifier": IPHONE + "-Max"}]):
            with self.subTest(types=types):
                result, calls = self.create([runtime(supportedDeviceTypes=types)])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("no preferred iPhone device type", result.stderr)
                self.assertEqual(len(calls), 1)

    def test_failed_create_does_not_publish_a_device_or_try_another(self):
        result, calls = self.create([runtime()], create_exit=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(len(calls), 2)
        self.assertIn("device creation failed", result.stderr)

    def test_failed_runtime_query_never_creates_device(self):
        result, calls = self.create([runtime()], list_exit=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(len(calls), 1)
        self.assertIn("runtime service unavailable", result.stderr)

    def test_invalid_created_udid_cleans_up_only_the_unique_created_name(self):
        for udid in ("booted", "all", "", OWNED_UDID.replace("-", ""), "not-a-uuid\n" + OWNED_UDID):
            with self.subTest(udid=udid):
                result, calls = self.create([runtime()], udid=udid)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertIn("invalid simulator UDID", result.stderr)
                self.assertEqual(len(calls), 3)
                self.assertEqual(calls[-1], ["simctl", "delete", calls[1][2]])

    def test_invalid_udid_cleanup_failure_reports_both_errors(self):
        result, calls = self.create([runtime()], udid="all", delete_exit=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("invalid simulator UDID", result.stderr)
        self.assertIn("device deletion failed", result.stderr)
        self.assertEqual(calls[-1], ["simctl", "delete", calls[1][2]])


if __name__ == "__main__":
    unittest.main()
