import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "scripts/generate_release_supplier_manifest.py"
FIXTURES = ROOT / "scripts/tests/fixtures/release_supplier"
BARNARD_REVISION = "61e2f0bacde14d78b18278bf743f587380f76cba"


class ReleaseSupplierManifestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(directory.cleanup)
        cls.source = Path(directory.name)

        def git(*args):
            return subprocess.check_output(["git", "-C", str(cls.source), *args], text=True).strip()

        git("init", "--quiet")
        ios_pins = json.dumps({
            "pins": [{"identity": "barnard", "state": {"version": "0.9.2", "revision": BARNARD_REVISION}}],
        })
        pins = {
            "ios/project.yml": "packages:\n  Barnard:\n    exactVersion: 0.9.2\n",
            "ios/Beid.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved": ios_pins,
            "android/app/build.gradle.kts": 'implementation("org.levarac:barnard:0.9.2")\n',
        }
        for relative, contents in pins.items():
            target = cls.source / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(contents, encoding="utf-8")
        git("add", "--", *pins)
        cls.source_commit = git(
            "-c", "user.name=Synthetic fixture", "-c", "user.email=fixture@example.invalid",
            "-c", "commit.gpgSign=false", "commit-tree", git("write-tree"), "-m", "Synthetic release pins",
        )
        # A different declaration in the working tree must never determine the selected revision.
        (cls.source / "android/app/build.gradle.kts").write_text(
            'implementation("org.levarac:barnard:0.9.3")\n', encoding="utf-8",
        )

    def run_tool(self, android: str, synthetic: bool = True, candidate: str | None = None,
                 existing: bool = False, receipt_commit: str | None = None):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        work = Path(directory.name)
        output = work / "manifest.json"
        if existing:
            output.write_text("preserve prior evidence", encoding="utf-8")

        def evidence(filename):
            data = json.loads((FIXTURES / filename).read_text(encoding="utf-8"))
            data["provenance"]["sourceCommit"] = receipt_commit or self.source_commit
            target = work / filename
            target.write_text(json.dumps(data), encoding="utf-8")
            return str(target)

        command = [
            "python3", str(TOOL), "--ios-evidence", evidence("ios-match.json"),
            "--android-evidence", evidence(android), "--candidate-sha", candidate or self.source_commit,
            "--root", str(self.source), "--output", str(output),
        ]
        if synthetic:
            command.append("--allow-synthetic")
        result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
        return result, output

    def test_success_has_only_parallax_export_shape(self):
        result, output = self.run_tool("android-match.json")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("2 builds, 2 agreeing Barnard identities", result.stdout)
        self.assertEqual(json.loads(output.read_text()), {
            "builds": {
                "ios": "1.1.0 (1042)",
                "android": "1.1.0 (1042)",
            },
            "barnard": {"tag": "v0.9.2", "commit": "61e2f0bacde14d78b18278bf743f587380f76cba"},
        })

    def test_missing_packaged_identity_stops_without_output(self):
        result, output = self.run_tool("android-missing-identity.json")
        self.assertEqual(result.returncode, 1)
        self.assertIn("missing packaged Barnard identity", result.stderr)
        self.assertFalse(output.exists())

    def test_mismatched_dependency_proof_stops_without_output(self):
        result, output = self.run_tool("android-mismatched-proof.json")
        self.assertEqual(result.returncode, 1)
        self.assertIn("dependency proof disagrees", result.stderr)
        self.assertFalse(output.exists())

    def test_stale_packaged_provenance_stops_without_output(self):
        result, output = self.run_tool("android-match.json", candidate="1" * 40)
        self.assertEqual(result.returncode, 1)
        self.assertIn("does not name candidate SHA", result.stderr)
        self.assertFalse(output.exists())

    def test_unknown_candidate_rejects_even_matching_receipts(self):
        missing = "1" * 40
        result, output = self.run_tool("android-match.json", candidate=missing, receipt_commit=missing)
        self.assertEqual(result.returncode, 1)
        self.assertIn("does not name a commit", result.stderr)
        self.assertFalse(output.exists())

    def test_existing_output_is_preserved(self):
        result, output = self.run_tool("android-match.json", existing=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(output.read_text(), "preserve prior evidence")

    def test_synthetic_evidence_requires_explicit_switch(self):
        result, output = self.run_tool("android-match.json", synthetic=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("requires --allow-synthetic", result.stderr)
        self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
