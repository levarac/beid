"""A corrupt release must be rejected before any archive content is extracted."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class DownloadXcodeGenTests(unittest.TestCase):
    def run_download(self, digest):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "scripts").mkdir()
            pins = root / "ios/ci_scripts"
            pins.mkdir(parents=True)
            (pins / "XCODEGEN_VERSION").write_text("2.45.3\n")
            if digest is not None:
                (pins / "XCODEGEN_SHA256").write_text(digest + "\n")
            helper = root / "scripts/download_xcodegen.sh"
            shutil.copyfile(ROOT / "scripts/download_xcodegen.sh", helper)
            fake = root / "bin"
            fake.mkdir()
            # curl writes known bytes; unzip records that extraction was reached.
            (fake / "curl").write_text('#!/bin/bash\nwhile [[ $# -gt 0 ]]; do\n if [[ "$1" == "--output" ]]; then printf verified > "$2"; exit; fi\n shift\ndone\nexit 1\n')
            (fake / "unzip").write_text('#!/bin/bash\nprintf reached > "$MARKER"\nmkdir -p "$4/xcodegen/share/xcodegen/SettingPresets" "$4/xcodegen/bin"\ntouch "$4/xcodegen/bin/xcodegen"\nchmod +x "$4/xcodegen/bin/xcodegen"\n')
            for path in fake.iterdir():
                path.chmod(0o755)
            marker = root / "extracted"
            env = {**os.environ, "PATH": str(fake) + os.pathsep + os.environ["PATH"], "MARKER": str(marker)}
            result = subprocess.run(["bash", str(helper), str(root / "out")], env=env, capture_output=True)
            return result.returncode, marker.exists()

    def test_corrupt_download_never_reaches_unzip(self):
        code, extracted = self.run_download("0" * 64)
        self.assertNotEqual(code, 0)
        self.assertFalse(extracted)

    def test_missing_pin_never_reaches_unzip(self):
        code, extracted = self.run_download(None)
        self.assertNotEqual(code, 0)
        self.assertFalse(extracted)

    def test_verified_archive_is_extracted(self):
        code, extracted = self.run_download(hashlib.sha256(b"verified").hexdigest())
        self.assertEqual(code, 0)
        self.assertTrue(extracted)

    def test_all_download_callers_use_the_verified_helper(self):
        paths = ["ios/ci_scripts/ci_post_clone.sh", "scripts/gha/build-and-upload-ios.sh",
                 ".github/workflows/pr-ci-ios-macos.yml", ".github/workflows/main-ios-release-build.yml"]
        for name in paths:
            text = (ROOT / name).read_text()
            self.assertIn("scripts/download_xcodegen.sh", text, name)
            self.assertNotIn("github.com/yonaskolb/XcodeGen/releases/download", text, name)
