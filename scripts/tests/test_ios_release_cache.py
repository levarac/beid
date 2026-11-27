import hashlib
import os
import subprocess
from pathlib import Path
import tempfile
import unittest

from scripts import ios_release_cache as cache


class ReleaseCacheTests(unittest.TestCase):
    def test_lookup_only_returns_compatible_entries_from_the_release_scope(self):
        prefix = "beid-ios-cas-v1-" + "a" * 64 + "-"
        key = prefix + "2026-W48-" + "b" * 64
        entries = [{"ref": "refs/pull/123/merge", "key": key, "version": "1" * 64},
                   {"ref": cache.RELEASE_REF, "key": key.replace("a" * 64, "c" * 64), "version": "1" * 64},
                   {"ref": cache.RELEASE_REF, "key": key + "bad", "version": "1" * 64}]
        self.assertEqual(cache.release_keys(entries, prefix, "cas", "1" * 64), [])
        entries.append({"ref": cache.RELEASE_REF, "key": key, "version": "1" * 64})
        self.assertEqual(cache.release_keys(entries, prefix, "cas", "1" * 64), [key])

    def test_export_fallback_still_requires_the_exact_kotlin_fingerprint(self):
        prefix = "beid-ios-export-v1-" + "a" * 64 + "-" + "b" * 64 + "-"
        key = prefix + "c" * 64
        entries = [{"ref": cache.RELEASE_REF, "key": key.replace("b" * 64, "d" * 64), "version": "1" * 64},
                   {"ref": cache.RELEASE_REF, "key": key, "version": "1" * 64}]
        self.assertEqual(cache.release_keys(entries, prefix, "export", "1" * 64), [key])

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


    def test_kmp_cache_contains_only_downloaded_dependency_directories(self):
        import yaml
        cache_paths = ["~/.gradle/caches/modules-2/files-2.1", "~/.konan/dependencies"]
        for filename in ("ios-release-cache-seed.yml", "pr-ci-ios-macos.yml"):
            workflow = yaml.safe_load((Path(".github/workflows") / filename).read_text())
            job = workflow["jobs"].get("seed", workflow["jobs"].get("build"))
            for step in job["steps"]:
                if step.get("name") not in ("Cache KMP dependencies", "Save release kmp dependencies",
                                           "Save KMP dependencies outside release PRs"):
                    continue
                self.assertEqual(step["with"]["path"].splitlines(), cache_paths)
                if step["name"] == "Cache KMP dependencies":
                    self.assertTrue(step["with"]["key"].startswith("beid-ios-kmp-v2-"))

    def test_xcode_install_requires_both_hosted_signals(self):
        import yaml
        project = yaml.safe_load(Path("ios/project.yml").read_text())
        phase = next(step["script"] for step in project["targets"]["Beid"]["preBuildScripts"]
                     if step["name"] == "Build BeidSharedKit")
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            src = root / "ios"
            scripts = root / "scripts"
            src.mkdir()
            scripts.mkdir()
            resolver = scripts / "resolve_kmp_java_home.sh"
            resolver.write_text("#!/bin/sh\necho build > \"$MARKER\"\nexit 23\n")
            resolver.chmod(0o755)
            install = root / "python3"
            install.write_text("#!/bin/sh\ntest \"$2\" = install || exit 24\necho restore > \"$MARKER\"\n")
            install.chmod(0o755)
            marker = root / "chosen"
            base = dict(PATH=str(root) + os.pathsep + os.defpath, SRCROOT=str(src),
                        CONFIGURATION="Debug", PLATFORM_NAME="iphonesimulator", ARCHS="arm64",
                        BEID_KMP_BUILD_TYPE="Release", BUILT_PRODUCTS_DIR=str(root / "products"),
                        BEID_SWIFT_EXPORT_KEY="a" * 64, BEID_SWIFT_EXPORT_ENTRY=str(root / "entry"),
                        MARKER=str(marker))
            for actions, runner, expected in [
                (None, None, "build"), ("true", None, "build"), (None, "github-hosted", "build"),
                ("true", "self-hosted", "build"), ("false", "github-hosted", "build"),
                ("true", "github-hosted", "restore"),
            ]:
                with self.subTest(actions=actions, runner=runner):
                    marker.unlink(missing_ok=True)
                    env = dict(base)
                    if actions is not None:
                        env["GITHUB_ACTIONS"] = actions
                    if runner is not None:
                        env["RUNNER_ENVIRONMENT"] = runner
                    result = subprocess.run(["/bin/sh", "-c", phase], env=env, capture_output=True)
                    self.assertEqual(marker.read_text().strip(), expected)
                    self.assertEqual(result.returncode, 0 if expected == "restore" else 23)

    def test_release_lookup_rejects_an_entry_for_a_different_archive_version(self):
        prefix = "beid-ios-cas-v1-" + "a" * 64 + "-"
        key = prefix + "2026-W48-" + "b" * 64
        entry = {"key": key, "ref": cache.RELEASE_REF, "version": "1" * 64}
        self.assertEqual(cache.release_keys([entry], prefix, "cas", "2" * 64), [])

    def test_gradle_version_matches_the_hosted_actions_cache_version(self):
        self.assertEqual(cache.archive_version(["~/.gradle/wrapper/dists"], "zstd-without-long"),
                         "52336038e8198e0113671af6bb97e025c95b711a7c8f3a3d8f72647442d8ad65")
        self.assertNotEqual(cache.archive_version(["~/.gradle/wrapper/dists"], "gzip"),
                            cache.archive_version(["~/.gradle/wrapper/dists"], "zstd-without-long"))

    def test_dependency_save_survives_optional_snapshot_failure(self):
        import yaml
        wf = yaml.safe_load(Path(".github/workflows/ios-release-cache-seed.yml").read_text())
        steps = wf["jobs"]["seed"]["steps"]
        names = [s.get("name") for s in steps]
        for kind in ("dist", "kmp", "spm"):
            save = names.index(f"Save release {kind} dependencies")
            self.assertLess(save, names.index("Save verified release snapshots"))
            self.assertIn("!cancelled()", steps[save]["if"])

    def test_recursive_archive_of_kmp_roots_contains_only_dependencies(self):
        import tarfile
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            paths = [p.removeprefix("~/") for p in cache.dependency_paths("kmp")]
            wanted = {".gradle/caches/modules-2/files-2.1/group/sdk.jar", ".konan/dependencies/llvm/bin/tool"}
            excluded = {".gradle/caches/build-cache-1/task-output", ".gradle/caches/9/executionHistory/history",
                        ".konan/cache/project-output"}
            for path in wanted | excluded:
                f = root / path
                f.parent.mkdir(parents=True, exist_ok=True)
                f.write_bytes(b"x")
            archive = root / "payload.tar"
            subprocess.run(["tar", "-cf", str(archive), "-T", "-"], cwd=root, input="\n".join(paths) + "\n",
                           text=True, check=True, env={**os.environ, "COPYFILE_DISABLE": "1"})
            with tarfile.open(archive) as stream:
                self.assertEqual({m.name for m in stream if m.isfile()}, wanted)

    def test_dependency_freshness_requires_version_scope_and_restore_hit(self):
        from unittest.mock import patch
        variables = {name.upper(): "beid-ios-" + name for name in ("dist", "kmp", "spm")}
        variables.update(DIST_HIT="true", KMP_HIT="false", SPM_HIT="true")
        def lookup(key):
            return [{"key": key, "ref": cache.RELEASE_REF, "version": "old" if key.endswith("spm") else "v"}]
        with patch.dict(os.environ, variables), patch.object(cache, "expected_version", return_value="v"), \
             patch.object(cache, "entries_for", side_effect=lookup):
            self.assertEqual(cache.dependencies(require_restore_hit=True), {"dist": True, "kmp": False, "spm": False})
            self.assertEqual(cache.dependencies(), {"dist": True, "kmp": True, "spm": False})

    def test_outer_archive_restore_is_scoped_to_disposable_release_prs(self):
        import yaml
        steps = yaml.safe_load(Path(".github/actions/ios-release-cache/action.yml").read_text())["runs"]["steps"]
        plan = next(s for s in steps if s.get("id") == "plan")
        self.assertIn("github.event_name == 'pull_request'", plan["if"])
        self.assertIn("github.event.pull_request.base.ref == 'release/1.1.0'", plan["if"])
        self.assertIn("runner.environment == 'github-hosted'", plan["if"])
        restores = [s for s in steps if s.get("uses", "").startswith("actions/cache/restore@")]
        self.assertEqual({s["id"] for s in restores}, {"restore_cas", "restore_export"})
        for step in restores:
            self.assertIn("steps.plan.outputs.", step["if"])
