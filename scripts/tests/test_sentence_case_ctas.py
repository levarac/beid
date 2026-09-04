import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[2]
PROPER_NOUNS = {"Bluetooth", "Coinbase", "MetaMask"}
ACRONYMS = {"URI"}


def balanced_calls(text, names):
    out = []
    for m in re.finditer(r"\b(?:" + "|".join(names) + r")\s*\(", text):
        start, depth, quote, escaped = m.start(), 0, False, False
        for i in range(m.end() - 1, len(text)):
            ch = text[i]
            if quote:
                if escaped: escaped = False
                elif ch == "\\": escaped = True
                elif ch == '"': quote = False
            elif ch == '"': quote = True
            elif ch == "(": depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    out.append(text[start:i + 1]); break
    return out


def sentence_case(value):
    words = re.findall(r"[A-Za-z]+", value)
    for i, word in enumerate(words[1:], 1):
        if word in PROPER_NOUNS or word in ACRONYMS or (word == "Wallet" and words[i - 1] == "Coinbase"):
            continue
        if word[0].isupper():
            return False
    return True


def swift_cta_literals(root):
    values = []
    for path in (root / "ios/Beid").rglob("*.swift"):
        text = path.read_text()
        for body in balanced_calls(text, ["BeidPrimaryButton", "BeidSecondaryButton", "Button"]):
            values += re.findall(r'"([^"\n]+)"', body)
        for m in re.finditer(r"\bButton\s*\{", text):
            values += re.findall(r'\bLabel\s*\(\s*"([^"\n]+)"', text[m.start():m.start() + 900])
    return values


def android_cta_resources(root):
    xml = (root / "android/app/src/main/res/values/strings.xml").read_text()
    values = dict(re.findall(r'<string name="([^"]+)">(.*?)</string>', xml))
    refs = set()
    for path in (root / "android/app/src/main/kotlin").rglob("*.kt"):
        for body in balanced_calls(path.read_text(), ["BeidPrimaryButton", "BeidSecondaryButton", "Button"]):
            refs.update(re.findall(r"R\.string\.([A-Za-z0-9_]+)", body))
    return {name: values[name] for name in refs if name in values}


class SentenceCaseCTAContractTests(unittest.TestCase):
    def test_all_ios_cta_literals_are_sentence_case(self):
        values = swift_cta_literals(ROOT)
        self.assertGreater(len(values), 10)
        self.assertTrue(all(sentence_case(v) for v in values), values)

    def test_all_android_cta_resources_are_sentence_case(self):
        values = android_cta_resources(ROOT)
        self.assertGreater(len(values), 10)
        self.assertTrue(all(sentence_case(v.replace("\\'", "'")) for v in values.values()), values)

    def test_all_ui_test_button_selectors_are_sentence_case(self):
        selectors = []
        for path in (ROOT / "ios/BeidUITests").rglob("*.swift"):
            selectors += re.findall(r'app\.buttons\["([^"]+)"\]', path.read_text())
        self.assertGreater(len(selectors), 20)
        self.assertTrue(all(sentence_case(v) for v in selectors), selectors)

    def test_catalog_contains_all_literal_ctas(self):
        keys = json.loads((ROOT / "ios/Beid/Localizable.xcstrings").read_text())["strings"]
        for value in swift_cta_literals(ROOT):
            if value not in {"Cancel", "Done", "Close"} and " " in value and "(demo)" not in value:
                self.assertIn(value, keys, value)

    def test_mutations_fail_for_unlisted_surfaces(self):
        self.assertFalse(sentence_case("Enter Event Code"))
        self.assertFalse(sentence_case("Join Event"))
        self.assertFalse(sentence_case("stale Selector"))
        self.assertTrue(sentence_case("Connect with MetaMask"))
        self.assertTrue(sentence_case("Copy URI"))


if __name__ == "__main__":
    unittest.main()
