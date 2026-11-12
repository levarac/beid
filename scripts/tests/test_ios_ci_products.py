"""Test the artifact handoff with tiny fake products, never a native build."""

import importlib
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest


class ProductArchiveTest(unittest.TestCase):
    def setUp(self):
        self.tool = importlib.import_module("scripts.ios_ci_products")

    def fixture(self, root):
        products = root / "source/Build/Products"
        products.mkdir(parents=True)
        executable = products / "Debug-iphonesimulator/Beid.app/Beid"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"executable")
        executable.chmod(0o755)
        (products / "Beid-link").symlink_to("Debug-iphonesimulator/Beid.app/Beid")
        with (products / "Beid.xctestrun").open("wb") as output:
            plistlib.dump({"TestHostPath": str(executable),
                          "TestBundlePath": "__TESTROOT__/Debug-iphonesimulator/BeidTests.xctest"}, output)
        manifest = root / "manifest.json"
        manifest.write_text(json.dumps({"sha": "a" * 40}))
        return root / "source", manifest

    def test_permissions_links_and_xctestrun_paths_survive_relocation(self):
        self.assertIsNotNone(self.tool, "portable product handoff is missing")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, manifest = self.fixture(root)
            archive = root / "products.tar"
            provenance = {"xcode": "Xcode 26.5\nBuild version 17F42", "sdk": "26.5", "arch": "arm64"}
            self.tool.pack(source, manifest, archive, provenance, root / "checkout1")
            destination = root / "other/DerivedData"
            run = self.tool.unpack(archive, destination, root / "checkout2", "a" * 40, provenance)
            self.assertEqual(run, destination / "Build/Products/Beid.xctestrun")
            self.assertTrue((destination / "Build/Products/Beid-link").is_symlink())
            self.assertTrue((destination / "Build/Products/Beid-link").stat().st_mode & 0o111)
            settings = plistlib.loads(run.read_bytes())
            self.assertTrue(settings["TestHostPath"].startswith(str(destination)))
            self.assertTrue(settings["TestBundlePath"].startswith("__TESTROOT__/"))
            for field in ("xcode", "sdk", "arch"):
                with self.subTest(field=field), self.assertRaises(ValueError):
                    self.tool.unpack(archive, root / field, root, "a" * 40, {**provenance, field: "wrong"})
            with self.assertRaises(ValueError):
                self.tool.unpack(archive, root / "wrong-head", root, "b" * 40, provenance)

    def test_missing_or_multiple_xctestruns_fail(self):
        self.assertIsNotNone(self.tool, "portable product handoff is missing")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, manifest = self.fixture(root)
            run = source / "Build/Products/Beid.xctestrun"
            content = run.read_bytes()
            run.unlink()
            with self.assertRaises(ValueError):
                self.tool.pack(source, manifest, root / "p.tar", {}, root)
            run.write_bytes(content)
            run.with_name("Other.xctestrun").write_bytes(content)
            with self.assertRaises(ValueError):
                self.tool.pack(source, manifest, root / "p.tar", {}, root)
