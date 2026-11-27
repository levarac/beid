import hashlib
from pathlib import Path
import tempfile
import unittest

from scripts import ios_release_cache as cache


class ReleaseCacheTests(unittest.TestCase):
    def test_lookup_only_returns_compatible_entries_from_the_release_scope(self):
        prefix = "beid-ios-cas-v1-" + "a" * 64 + "-"
        key = prefix + "2026-W48-" + "b" * 64
        entries = [{"ref": "refs/pull/123/merge", "key": key},
                   {"ref": cache.RELEASE_REF, "key": key.replace("a" * 64, "c" * 64)},
                   {"ref": cache.RELEASE_REF, "key": key + "bad"}]
        self.assertEqual(cache.release_keys(entries, prefix, "cas"), [])
        entries.append({"ref": cache.RELEASE_REF, "key": key})
        self.assertEqual(cache.release_keys(entries, prefix, "cas"), [key])

    def test_export_fallback_still_requires_the_exact_kotlin_fingerprint(self):
        prefix = "beid-ios-export-v1-" + "a" * 64 + "-" + "b" * 64 + "-"
        key = prefix + "c" * 64
        entries = [{"ref": cache.RELEASE_REF, "key": key.replace("b" * 64, "d" * 64)},
                   {"ref": cache.RELEASE_REF, "key": key}]
        self.assertEqual(cache.release_keys(entries, prefix, "export"), [key])

    def test_only_a_release_verified_archive_is_installed(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            src = root / "src"
            src.mkdir()
            (src / "object").write_bytes(b"object")
            archive = root / "payload.tar"
            digest = cache.pack(src, archive)
            self.assertEqual(digest, hashlib.sha256(archive.read_bytes()).hexdigest())
            key = "beid-ios-cas-v1-" + "a" * 64 + "-2026-W48-" + digest
            dest = root / "dest"
            with self.assertRaises(ValueError):
                cache.restore(archive, dest, key, [])
            self.assertFalse(dest.exists())
            cache.restore(archive, dest, key, [key])
            self.assertEqual((dest / "object").read_bytes(), b"object")
            archive.write_bytes(b"different contents")
            with self.assertRaises(ValueError):
                cache.restore(archive, root / "bad", key, [key])
            self.assertFalse((root / "bad").exists())

    def test_release_seed_uses_the_same_dependency_paths_and_keys_as_the_pr(self):
        import yaml
        wf = Path(".github/workflows")
        seed = yaml.safe_load((wf / "ios-release-cache-seed.yml").read_text())
        self.assertEqual(list(seed[True]), ["push"])
        self.assertEqual(seed[True]["push"]["branches"], ["release/1.1.0"])
        for step in seed["jobs"]["seed"]["steps"]:
            self.assertNotIn("pull_request", str(step.get("if", "")))
        build = yaml.safe_load((wf / "pr-ci-ios-macos.yml").read_text())["jobs"]["build"]
        producer_steps = {step["name"]: step for step in seed["jobs"]["seed"]["steps"] if "name" in step}
        pr_steps = {step["name"]: step for step in build["steps"] if "name" in step}
        for name, cache in [("Restore Gradle distribution", "dist"), ("Cache KMP dependencies", "kmp"),
                            ("Cache SPM checkouts", "spm")]:
            self.assertEqual(producer_steps[name]["with"], pr_steps[name]["with"])
            saved = producer_steps[f"Save release {cache} dependencies"]["with"]
            self.assertEqual(saved["path"], pr_steps[name]["with"]["path"])
            self.assertEqual(saved["key"], "${{ steps." + cache + ".outputs.cache-primary-key }}")
