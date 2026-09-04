import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
HARNESS = ROOT / "android/app/src/androidTest/kotlin/org/levarac/beid/devicelab/TwoDeviceBleDiscoveryTest.kt"
DOC = ROOT / "docs/device-lab-android-harness.md"


class AndroidDeviceLabHarnessContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.harness = HARNESS.read_text(encoding="utf-8")
        cls.doc = DOC.read_text(encoding="utf-8")

    def test_ready_depends_on_confirmed_async_callbacks(self) -> None:
        self.assertIn('"advertise_started"', self.harness)
        self.assertIn('"ble_discovery_result"', self.harness)
        self.assertNotRegex(
            self.harness,
            re.compile(r"waitUntil\([^)]*\)\s*\{\s*harness\.engine\.getState\(\)\.is(?:Advertising|Scanning)"),
        )
        self.assertIn('emitRunnerSignal("DEVICE_LAB_ROLE=advertiser READY")', self.harness)
        self.assertIn('emitRunnerSignal("DEVICE_LAB_ROLE=scanner READY")', self.harness)

    def test_roles_and_machine_parseable_results_are_explicit(self) -> None:
        self.assertIn('const val ROLE_ADVERTISER = "advertiser"', self.harness)
        self.assertIn('const val ROLE_SCANNER = "scanner"', self.harness)
        self.assertIn('"RESULT role=$role status=PASS', self.harness)
        self.assertIn('"RESULT role=$role status=FAIL', self.harness)

    def test_argument_and_setup_failures_are_inside_result_boundary(self) -> None:
        result_boundary = self.harness.index("        try {")
        argument_parsing = self.harness.index("        val eventCode")
        harness_creation = self.harness.index("        val harness = createHarness()")
        self.assertLess(result_boundary, argument_parsing)
        self.assertLess(result_boundary, harness_creation)

    def test_docs_state_human_and_per_serial_prerequisites(self) -> None:
        self.assertNotIn("Unattended", self.doc)
        self.assertIn("human operator", self.doc)
        self.assertIn("adb -s <advertiser-serial>", self.doc)
        self.assertIn("adb -s <scanner-serial>", self.doc)


if __name__ == "__main__":
    unittest.main()
