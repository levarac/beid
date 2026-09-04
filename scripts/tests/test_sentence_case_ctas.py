import json
import re
import unittest
import tempfile
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


def balanced_brace(text, start):
    depth, quote, escaped = 0, False, False
    for i in range(start, len(text)):
        ch = text[i]
        if quote:
            if escaped: escaped = False
            elif ch == "\\": escaped = True
            elif ch == '"': quote = False
        elif ch == '"': quote = True
        elif ch == "{": depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0: return text[start:i + 1]
    return ""


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
        for m in re.finditer(r"\b(?:BeidPrimaryButton|BeidSecondaryButton|Button)\b", text):
            pos = m.end()
            had_call = False
            while pos < len(text) and text[pos].isspace(): pos += 1
            if pos < len(text) and text[pos] == "(":
                bodies = balanced_calls(text[m.start():], [m.group(0)])
                if bodies:
                    body = bodies[0]
                    values += re.findall(r'"([^"\n]+)"', body)
                    pos = m.start() + len(body)
                    had_call = True
            while pos < len(text) and text[pos].isspace(): pos += 1
            if pos < len(text) and text[pos] == "{":
                first = balanced_brace(text, pos)
                pos += len(first)
                label_match = re.match(r"\s*label\s*:\s*\{", text[pos:])
                if label_match:
                    label_start = pos + label_match.end() - 1
                    label = balanced_brace(text, label_start)
                    pos = label_start + len(label)
                    values += re.findall(r'\b(?:Label|Text)\s*\(\s*"([^"\n]+)"', label)
                elif had_call:
                    label = first
                    values += re.findall(r'\b(?:Label|Text)\s*\(\s*"([^"\n]+)"', label)
                values += re.findall(r'\.accessibilityLabel\s*\(\s*(?:Text\s*\(\s*)?"([^"\n]+)"', text[pos:pos + 500])
    return values


def ui_test_selectors(root):
    selectors = []
    for path in (root / "ios/BeidUITests").rglob("*.swift"):
        text = path.read_text()
        for m in re.finditer(r"app\s*\.\s*buttons\s*\[", text):
            start = m.end(); depth = 1; quote = False; escaped = False
            for i in range(start, len(text)):
                ch = text[i]
                if quote:
                    if escaped: escaped = False
                    elif ch == "\\": escaped = True
                    elif ch == '"': quote = False
                elif ch == '"': quote = True
                elif ch == "[": depth += 1
                elif ch == "]":
                    depth -= 1
                    if depth == 0:
                        expr = text[start:i].strip()
                        literal = re.fullmatch(r'"([^"\n]*)"', expr)
                        if literal:
                            selectors.append(literal.group(1)); break
                        strings = balanced_calls(expr, ["String"])
                        if strings:
                            inner = re.search(r'"([^"\n]*)"', strings[0])
                            if inner:
                                selectors.append(inner.group(1)); break
                        raise AssertionError(f"uninspectable selector: {expr}")
    return selectors


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
        selectors = ui_test_selectors(ROOT)
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

    def test_real_source_mutations_are_discovered_and_red(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for rel in ["ios/Beid/Views/AccountSheetView.swift", "ios/Beid/Views/ScanFlowView.swift"]:
                dst = root / rel
                dst.parent.mkdir(parents=True, exist_ok=True)
                dst.write_text((ROOT / rel).read_text())
            account = root / "ios/Beid/Views/AccountSheetView.swift"
            account.write_text(account.read_text().replace('Label("Connect wallet", systemImage:', 'Text("Connect Wallet")\n              // mutation\n              Label("Connect wallet", systemImage:', 1))
            scan = root / "ios/Beid/Views/ScanFlowView.swift"
            scan.write_text(scan.read_text().replace('.accessibilityLabel("Close")', '.accessibilityLabel(\n              Text("Close Panel")\n            )', 1))
            self.assertIn("Connect Wallet", swift_cta_literals(root))
            self.assertIn("Close Panel", swift_cta_literals(root))
            self.assertFalse(sentence_case("Connect Wallet"))
            self.assertFalse(sentence_case("Close Panel"))

            ui = root / "ios/BeidUITests/Mutation.swift"
            ui.parent.mkdir(parents=True)
            ui.write_text('app\n  .buttons[\n    "Get Started"\n  ]')
            selectors = ui_test_selectors(root)
            self.assertEqual(["Get Started"], selectors)
            self.assertFalse(sentence_case(selectors[0]))

            standard = root / "ios/Beid/Views/Standard.swift"
            standard.write_text('Button(action: { }) {\n  VStack { Text("Join Event") }\n}')
            self.assertIn("Join Event", swift_cta_literals(root))

            android_xml = root / "android/app/src/main/res/values/strings.xml"
            android_xml.parent.mkdir(parents=True, exist_ok=True)
            android_xml.write_text('<resources><string name="mutated">Enter Event Code</string></resources>')
            kotlin = root / "android/app/src/main/kotlin/Mutation.kt"
            kotlin.parent.mkdir(parents=True, exist_ok=True)
            kotlin.write_text('BeidPrimaryButton(text = stringResource(R.string.mutated)) {}')
            mutated = android_cta_resources(root)
            self.assertEqual("Enter Event Code", mutated["mutated"])
            self.assertFalse(sentence_case(mutated["mutated"]))


if __name__ == "__main__":
    unittest.main()
