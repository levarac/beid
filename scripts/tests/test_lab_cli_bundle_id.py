"""Pins beid-lab-cli's bundle identifier in the two places that must agree.

macOS keys a Bluetooth grant to the bundle identifier plus the code
signature. `scripts/bundle.sh` writes the identifier into Info.plist and
signs under it; `LabBundle.identifier` is what the binary reports as its own.
If they drift, the tool logs one identity while macOS grants another, and a
grant made against either is lost the moment the other is "fixed" to match.

The identifier is also a decision (Ken, 2026-09-18: org.levarac.beid.lab-cli),
so it is pinned to a literal rather than only to agreement: renaming it
throws away every existing grant on every host and must be a visible change.
"""
import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
TOOL_DIR = REPO_ROOT / "tools" / "beid-lab-cli"
BUNDLE_SH = TOOL_DIR / "scripts" / "bundle.sh"
ENGINE_LOGGING = TOOL_DIR / "Sources" / "beid-lab-cli" / "EngineLogging.swift"

EXPECTED = "org.levarac.beid.lab-cli"

SHELL_PATTERN = re.compile(r'^BUNDLE_ID="([^"]*)"\s*$', re.MULTILINE)
SWIFT_PATTERN = re.compile(r'^\s*static let identifier = "([^"]*)"\s*$', re.MULTILINE)


def extract(text: str, pattern: re.Pattern) -> str:
    """Return the single value `pattern` captures, or raise.

    Exactly one match is required: zero means the declaration moved and this
    test would otherwise compare nothing, and two means it is ambiguous which
    one the build uses.
    """
    found = pattern.findall(text)
    if len(found) != 1:
        raise ValueError(f"expected exactly one match for {pattern.pattern!r}, found {len(found)}")
    return found[0]


class LabCliBundleIdTest(unittest.TestCase):
    def test_bundle_script_and_binary_agree(self):
        shell = extract(BUNDLE_SH.read_text(encoding="utf-8"), SHELL_PATTERN)
        swift = extract(ENGINE_LOGGING.read_text(encoding="utf-8"), SWIFT_PATTERN)
        self.assertEqual(shell, swift)

    def test_identifier_is_the_decided_value(self):
        shell = extract(BUNDLE_SH.read_text(encoding="utf-8"), SHELL_PATTERN)
        self.assertEqual(EXPECTED, shell)

    def test_extract_refuses_to_pass_on_a_missing_declaration(self):
        with self.assertRaises(ValueError):
            extract("# no identifier here\n", SHELL_PATTERN)
        with self.assertRaises(ValueError):
            extract("enum LabBundle {}\n", SWIFT_PATTERN)

    def test_extract_refuses_an_ambiguous_declaration(self):
        with self.assertRaises(ValueError):
            extract('BUNDLE_ID="a"\nBUNDLE_ID="b"\n', SHELL_PATTERN)

    def test_a_drifted_pair_is_detected(self):
        shell = extract('BUNDLE_ID="org.levarac.beid.lab-cli"\n', SHELL_PATTERN)
        swift = extract('  static let identifier = "org.levarac.beid.LabCli"\n', SWIFT_PATTERN)
        self.assertNotEqual(shell, swift)


if __name__ == "__main__":
    unittest.main()
