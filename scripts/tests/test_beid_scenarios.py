from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "beid_scenarios.py"

spec = importlib.util.spec_from_file_location("beid_scenarios", SCRIPT)
assert spec and spec.loader
beid_scenarios = importlib.util.module_from_spec(spec)
spec.loader.exec_module(beid_scenarios)


class ParsesRealSources(unittest.TestCase):
    """Against the checked-in sources, not against a fixture string.

    A fixture would prove the regex matches text I wrote to match it. The
    thing worth pinning is that it still matches what the repository actually
    contains — which is the failure that would make this tool quietly print an
    empty roster after someone reformats either file.
    """

    def test_both_rosters_are_non_empty(self):
        ios, android = beid_scenarios.load_rosters()
        self.assertTrue(ios, "iOS roster is empty: the parse no longer matches DemoScenario.swift")
        self.assertTrue(android, "Android roster is empty: the parse no longer matches the enum")

    def test_appreviewgolden_is_present_on_both(self):
        # The one identifier both platforms must always carry: it is the
        # fallback each app uses for an unknown or missing launch value.
        ios, android = beid_scenarios.load_rosters()
        self.assertIn("appReviewGolden", ios)
        self.assertIn("appReviewGolden", android)


class ParsingShape(unittest.TestCase):
    def test_ios_identifiers_come_from_initialisers_in_source_order(self):
        swift = '''
        static var a: DemoScenario { DemoScenario(identifier: "alpha", event: e, steps: s) }
        static let b = DemoScenario(identifier: "beta", event: e, steps: s)
        '''
        self.assertEqual(["alpha", "beta"], beid_scenarios.parse_ios_scenarios(swift))

    def test_android_identifiers_come_from_the_enum_body_only(self):
        kotlin = '''
        enum class AndroidDemoScenario(val identifier: String) {
            Alpha("alpha"),
            Beta("beta"),
            ;
            companion object {
                fun named(identifier: String) = entries.firstOrNull { it.identifier == identifier }
            }
        }
        enum class Unrelated(val identifier: String) { Gamma("gamma"), ; }
        '''
        self.assertEqual(["alpha", "beta"], beid_scenarios.parse_android_scenarios(kotlin))

    def test_a_renamed_enum_yields_nothing_rather_than_guessing(self):
        kotlin = 'enum class SomethingElse(val identifier: String) { Alpha("alpha"), ; }'
        self.assertEqual([], beid_scenarios.parse_android_scenarios(kotlin))


class RosterDifference(unittest.TestCase):
    def test_reports_each_side_separately(self):
        ios_only, android_only = beid_scenarios.roster_difference(
            ["appReviewGolden", "onlyOnIos"], ["appReviewGolden", "onlyOnAndroid"]
        )
        self.assertEqual(["onlyOnIos"], ios_only)
        self.assertEqual(["onlyOnAndroid"], android_only)

    def test_agreement_is_an_empty_pair_not_a_special_case(self):
        same = ["appReviewGolden", "crowdSurge"]
        self.assertEqual(([], []), beid_scenarios.roster_difference(same, list(reversed(same))))


class LaunchCommands(unittest.TestCase):
    def test_ios_uses_a_concrete_udid_and_the_scenario_argument(self):
        self.assertEqual(
            ["xcrun", "simctl", "launch", "UDID-1", "org.levarac.beid",
             "-beid-demo-scenario", "crowdSurge"],
            beid_scenarios.ios_launch_command("UDID-1", "crowdSurge"),
        )

    def test_android_omits_the_surface_extra_when_none_is_asked_for(self):
        command = beid_scenarios.android_launch_command("crowdSurge")
        self.assertNotIn("beid-demo-surface", command)
        self.assertEqual(command[-2:], ["beid-demo-scenario", "crowdSurge"])

    def test_android_appends_the_surface_extra_when_asked(self):
        self.assertEqual(
            ["adb", "shell", "am", "start", "-n", "org.levarac.beid/.MainActivity",
             "--es", "beid-demo-scenario", "crowdSurge",
             "--es", "beid-demo-surface", "records"],
            beid_scenarios.android_launch_command("crowdSurge", "records"),
        )


class Refusals(unittest.TestCase):
    """The refusals are the point of the tool, so they are pinned.

    Both apps fall back to appReviewGolden for an unknown scenario so that an
    App Review launch never lands on a blank screen. Passing a typo through
    would therefore launch *something* and look like it worked.
    """

    def test_a_scenario_the_platform_lacks_is_refused(self):
        code = beid_scenarios.main(
            ["run", "--platform", "ios", "--scenario", "notAScenario",
             "--udid", "UDID-1", "--dry-run"]
        )
        self.assertEqual(2, code)

    def test_ios_surface_is_refused_while_the_argument_does_not_exist(self):
        code = beid_scenarios.main(
            ["run", "--platform", "ios", "--scenario", "appReviewGolden",
             "--surface", "records", "--udid", "UDID-1", "--dry-run"]
        )
        self.assertEqual(2, code)

    def test_ios_without_a_udid_is_refused(self):
        code = beid_scenarios.main(
            ["run", "--platform", "ios", "--scenario", "appReviewGolden", "--dry-run"]
        )
        self.assertEqual(2, code)

    def test_an_unknown_android_surface_is_refused(self):
        code = beid_scenarios.main(
            ["run", "--platform", "android", "--scenario", "appReviewGolden",
             "--surface", "notASurface", "--dry-run"]
        )
        self.assertEqual(2, code)

    def test_a_valid_android_launch_is_accepted(self):
        code = beid_scenarios.main(
            ["run", "--platform", "android", "--scenario", "appReviewGolden",
             "--surface", "records", "--dry-run"]
        )
        self.assertEqual(0, code)


if __name__ == "__main__":
    unittest.main()
