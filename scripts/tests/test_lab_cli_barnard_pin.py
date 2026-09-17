"""Tests for scripts/check_lab_cli_barnard_pin.py.

The checker exists because the drift it catches produces no build error, so
its own silent-pass failure mode matters as much as its logic: every negative
case here plants a real disagreement in a copy of the tree and asserts the
checker notices.
"""
import importlib.util
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
CHECKER = REPO_ROOT / "scripts" / "check_lab_cli_barnard_pin.py"

spec = importlib.util.spec_from_file_location("check_lab_cli_barnard_pin", CHECKER)
checker = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = checker
spec.loader.exec_module(checker)

TRACKED = (checker.PROJECT_YML, checker.CLI_PACKAGE, checker.CLI_RESOLVED)


class ReadingTest(unittest.TestCase):
    def test_reads_both_pins_from_the_real_tree(self):
        app = checker.project_pin(REPO_ROOT)
        cli = checker.cli_pin(REPO_ROOT)
        self.assertEqual(app, cli)
        version, revision = checker.cli_resolved(REPO_ROOT)
        self.assertEqual(cli, version)
        self.assertEqual(40, len(revision))

    def test_a_version_under_another_package_is_not_mistaken_for_barnard(self):
        with sandbox() as root:
            path = root / checker.PROJECT_YML
            path.write_text(
                "packages:\n"
                "  MetaMask:\n"
                "    url: https://example.test/metamask\n"
                "    exactVersion: 9.9.9\n"
                "  Barnard:\n"
                "    url: https://github.com/levarac/barnard.git\n"
                "    exactVersion: 0.9.2\n",
                encoding="utf-8",
            )
            self.assertEqual("0.9.2", checker.project_pin(root))

    def test_a_range_pin_in_the_cli_is_refused(self):
        with sandbox() as root:
            path = root / checker.CLI_PACKAGE
            path.write_text(
                'dependencies: [.package(url: "https://github.com/levarac/barnard.git", '
                'from: "0.9.2")]\n',
                encoding="utf-8",
            )
            with self.assertRaises(SystemExit):
                checker.cli_pin(root)


class MainTest(unittest.TestCase):
    def test_the_real_tree_agrees(self):
        self.assertEqual(0, run(REPO_ROOT))

    def test_a_bumped_app_pin_is_caught(self):
        with sandbox() as root:
            path = root / checker.PROJECT_YML
            path.write_text(
                path.read_text(encoding="utf-8").replace("exactVersion: 0.9.2", "exactVersion: 0.9.3"),
                encoding="utf-8",
            )
            self.assertEqual(1, run(root))

    def test_a_bumped_cli_pin_is_caught(self):
        with sandbox() as root:
            path = root / checker.CLI_PACKAGE
            path.write_text(
                path.read_text(encoding="utf-8").replace('exact: "0.9.2"', 'exact: "0.9.3"'),
                encoding="utf-8",
            )
            self.assertEqual(1, run(root))

    def test_a_stale_resolved_file_is_caught(self):
        with sandbox() as root:
            path = root / checker.CLI_RESOLVED
            document = json.loads(path.read_text(encoding="utf-8"))
            document["pins"][0]["state"]["version"] = "0.9.1"
            path.write_text(json.dumps(document), encoding="utf-8")
            self.assertEqual(1, run(root))

    def test_a_missing_resolved_file_fails_rather_than_passing(self):
        with sandbox() as root:
            (root / checker.CLI_RESOLVED).unlink()
            with self.assertRaises(SystemExit):
                run(root)


class sandbox:
    """A copy of just the three files the checker reads."""

    def __enter__(self):
        self._directory = tempfile.TemporaryDirectory()
        root = Path(self._directory.name)
        for relative in TRACKED:
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPO_ROOT / relative, target)
        return root

    def __exit__(self, *_):
        self._directory.cleanup()
        return False


def run(root):
    argv = sys.argv
    sys.argv = ["check_lab_cli_barnard_pin.py", "--root", str(root)]
    try:
        return checker.main()
    finally:
        sys.argv = argv


if __name__ == "__main__":
    unittest.main()
