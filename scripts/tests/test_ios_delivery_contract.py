import importlib.util
from pathlib import Path
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
HELPER_PATH = REPO_ROOT / "scripts" / "gha" / "resolve_ios_delivery.py"


def load_helper():
    spec = importlib.util.spec_from_file_location("resolve_ios_delivery", HELPER_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {HELPER_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class IOSDeliveryContractTests(unittest.TestCase):
    def test_internal_channel_selects_only_internal_scheme_and_configuration(self):
        helper = load_helper()
        self.assertEqual(
            helper.resolve("internal", "Beid-Internal", "Internal"),
            ("Beid-Internal", "Internal"),
        )

    def test_release_channel_selects_only_release_scheme_and_configuration(self):
        helper = load_helper()
        self.assertEqual(
            helper.resolve("release", "Beid", "Release"),
            ("Beid", "Release"),
        )

    def test_missing_unknown_and_mismatched_inputs_fail_closed(self):
        helper = load_helper()
        invalid = [
            ("", "Beid", "Release"),
            ("preview", "Beid", "Release"),
            ("internal", "Beid", "Internal"),
            ("internal", "Beid-Internal", "Release"),
            ("release", "Beid-Internal", "Internal"),
            ("release", "Beid", "Internal"),
        ]
        for values in invalid:
            with self.subTest(values=values), self.assertRaises(ValueError):
                helper.resolve(*values)


if __name__ == "__main__":
    unittest.main()
