import re
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[2]


class SentenceCaseCTAContractTests(unittest.TestCase):
    """Keep the reviewed button/CTA surface in sentence case.

    The patterns intentionally inspect only SwiftUI button constructors,
    action labels/accessibility labels, and Android resources used by the
    known CTA resource names; ordinary body copy is out of scope.
    """

    IOS_EXPECTED = {
        "Get Started": "Get started",
        "Sense Event": "Sense event",
        "Join Event": "Join event",
        "Connect Wallet": "Connect wallet",
        "Disconnect Wallet": "Disconnect wallet",
        "Leave Event": "Leave event",
        "Start Over": "Start over",
        "Copy URI": "Copy URI",
        "Try Again": "Try again",
        "Simulate Signal Lost": "Simulate signal lost",
        "Open Settings": "Open settings",
    }

    ANDROID_EXPECTED = {
        "welcome_get_started": "Get started",
        "bluetooth_permission_allow_button": "Allow Bluetooth",
        "bluetooth_off_open_settings_button": "Open settings",
        "bluetooth_off_turned_on_button": "I've turned it on",
        "event_join_button": "Join event",
        "event_join_open_settings": "Open settings",
        "account_leave_event_button": "Leave event",
    }

    IOS_EXPLICIT = {
        "account.joinEvent.label": "Join event",
        "account.pastEvents.label": "Past events",
    }

    IOS_CATALOG_KEYS = {
        "Get started",
        "Join event",
        "Sense event",
        "Connect wallet",
        "Disconnect wallet",
        "Venue device",
        "Leave event",
        "Start over",
        "Try again",
        "Simulate signal lost",
        "Open settings",
    }

    def test_ios_reviewed_button_literals_are_sentence_case(self):
        views = "\n".join(
            p.read_text() for p in (ROOT / "ios/Beid/Views").glob("*.swift")
        )
        patterns = (
            r"(?:Beid(?:Primary|Secondary)Button|Button\(|Label\(|\.accessibilityLabel\()[^\n]*?\"([^\"]+)\""
        )
        literals = set()
        for match in re.finditer(patterns, views):
            literals.add(match.group(1))
        for old, new in self.IOS_EXPECTED.items():
            if old != new:
                self.assertNotIn(old, literals, f"iOS CTA remains title case: {old}")
            self.assertIn(new, literals, f"iOS CTA missing sentence-case form: {new}")

    def test_android_reviewed_button_resources_are_sentence_case(self):
        text = (ROOT / "android/app/src/main/res/values/strings.xml").read_text()
        for name, expected in self.ANDROID_EXPECTED.items():
            match = re.search(rf'<string name="{name}">(.*?)</string>', text)
            self.assertIsNotNone(match, f"missing Android CTA resource: {name}")
            self.assertEqual(expected.replace("'", "\\'"), match.group(1), name)

    def test_ios_explicit_button_keys_are_sentence_case(self):
        import json

        catalog = json.loads((ROOT / "ios/Beid/Localizable.xcstrings").read_text())
        self.assertTrue(self.IOS_CATALOG_KEYS <= catalog["strings"].keys())
        for key, expected in self.IOS_EXPLICIT.items():
            value = catalog["strings"][key]["localizations"]["en"]["stringUnit"]["value"]
            self.assertEqual(expected, value, key)

        account_source = (ROOT / "ios/Beid/Views/AccountSheetView.swift").read_text()
        past_events_source = (ROOT / "ios/Beid/Views/PastEventsView.swift").read_text()
        self.assertIn('defaultValue: "Join event"', account_source)
        self.assertIn('defaultValue: "Past events"', account_source)
        self.assertIn('localized: "account.pastEvents.title", defaultValue: "Past Events"', past_events_source)

    def test_android_cta_resources_are_referenced_by_production_ui(self):
        source = "\n".join(
            p.read_text()
            for p in (ROOT / "android/app/src/main/kotlin").rglob("*.kt")
        )
        for name in self.ANDROID_EXPECTED:
            self.assertIn(f"R.string.{name}", source, name)


if __name__ == "__main__":
    unittest.main()
