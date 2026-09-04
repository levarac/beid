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

    def function_body(self, name: str, source: str | None = None) -> str:
        source = self.harness if source is None else source
        function_start = source.index(f"    private fun {name}(")
        body_start = source.index("{", function_start)
        depth = 0
        for position in range(body_start, len(source)):
            if source[position] == "{":
                depth += 1
            elif source[position] == "}":
                depth -= 1
                if depth == 0:
                    return source[body_start + 1 : position]
        self.fail(f"Could not find end of {name}")

    def ready_is_control_dependent_on_success(self, role: str, source: str | None = None) -> bool:
        body = self.function_body(f"run{role.title()}", source)
        if role == "advertiser":
            callback = 'event.name == "advertise_started"'
            guard = re.compile(
                r"if \(!startFinished\.await\([^\n]+\) \|\| !advertisingConfirmed\.get\(\)\) \{"
                r"[\s\S]*?fail\([^\n]+\)\s*\}\s*"
                r'emitRunnerSignal\("DEVICE_LAB_ROLE=advertiser READY"\)',
            )
        else:
            callback = 'event.name == "ble_discovery_result"'
            guard = re.compile(
                r"if \(!scanObserved\.await\([^\n]+\) \|\| !advertisementSeen\.get\(\)\) \{"
                r"[\s\S]*?fail\([^\n]+\)\s*\}\s*"
                r'emitRunnerSignal\("DEVICE_LAB_ROLE=scanner READY"\)',
            )
        return callback in body and guard.search(body) is not None

    def test_ready_depends_on_confirmed_async_callbacks(self) -> None:
        self.assertTrue(self.ready_is_control_dependent_on_success("advertiser"))
        self.assertTrue(self.ready_is_control_dependent_on_success("scanner"))
        self.assertNotRegex(
            self.harness,
            re.compile(r"waitUntil\([^)]*\)\s*\{\s*harness\.engine\.getState\(\)\.is(?:Advertising|Scanning)"),
        )

    def test_premature_ready_mutations_fail_the_oracle(self) -> None:
        for role, guard_start in (
            ("advertiser", "        if (!startFinished.await"),
            ("scanner", "        if (!scanObserved.await"),
        ):
            ready = f'        emitRunnerSignal("DEVICE_LAB_ROLE={role} READY")\n'
            body = self.function_body(f"run{role.title()}")
            mutated_body = body.replace(ready, "", 1).replace(guard_start, ready + guard_start, 1)
            mutated_source = self.harness.replace(body, mutated_body, 1)
            self.assertFalse(
                self.ready_is_control_dependent_on_success(role, mutated_source),
                f"{role} READY moved before success guard must fail the contract oracle",
            )

    def test_roles_and_machine_parseable_results_are_explicit(self) -> None:
        self.assertIn('const val ROLE_ADVERTISER = "advertiser"', self.harness)
        self.assertIn('const val ROLE_SCANNER = "scanner"', self.harness)
        self.assertIn('"role=$role status=PASS $details"', self.harness)
        self.assertIn('emitRunnerSignal("RESULT $passResult")', self.harness)
        self.assertIn('status=FAIL reason=', self.harness)
        self.assertEqual(2, len(re.findall(r'emitRunnerSignal\(\s*"RESULT', self.harness)))
        self.assertIn("resultToken(failure.message ?: failure.javaClass.simpleName)", self.harness)

    def test_argument_permission_and_activity_failures_are_inside_result_boundary(self) -> None:
        self.assertIn("RuleChain.outerRule(resultBoundaryRule)", self.harness)
        self.assertIn(".around(runtimePermissionRule)", self.harness)
        self.assertIn(".around(activityRule)", self.harness)
        self.assertNotRegex(self.harness, re.compile(r"@get:Rule\([^)]*order"))
        boundary = self.harness.index("private val resultBoundaryRule")
        boundary_try = self.harness.index("try {", boundary)
        base_evaluate = self.harness.index("base.evaluate()", boundary_try)
        pass_result = self.harness.index('emitRunnerSignal("RESULT $passResult")', base_evaluate)
        fail_result = self.harness.index('status=FAIL reason=', base_evaluate)
        self.assertLess(boundary_try, base_evaluate)
        self.assertLess(base_evaluate, pass_result)
        self.assertLess(base_evaluate, fail_result)

    def test_docs_state_human_and_per_serial_prerequisites(self) -> None:
        self.assertNotIn("Unattended", self.doc)
        self.assertIn("human operator", self.doc)
        self.assertIn("adb -s <advertiser-serial>", self.doc)
        self.assertIn("adb -s <scanner-serial>", self.doc)

    def test_docs_list_every_result_line_form(self):
        docs = self.doc
        self.assertIn("RESULT role=advertiser status=PASS holdSeconds=N", docs)
        self.assertIn("RESULT role=scanner status=PASS peer=SHORT_ID ms=ELAPSED", docs)
        self.assertIn("RESULT role=ROLE status=FAIL reason=TOKEN", docs)
        self.assertIn('"role=$role status=PASS $details"', self.harness)
        self.assertIn('recordPassResult(ROLE_ADVERTISER, "holdSeconds=$holdSeconds")', self.harness)
        self.assertIn('status=FAIL reason=', self.harness)


if __name__ == "__main__":
    unittest.main()
