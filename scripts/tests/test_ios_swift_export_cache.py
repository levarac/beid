import tempfile
import unittest
from pathlib import Path

from scripts import ios_swift_export_cache as cache


class ExportCacheTests(unittest.TestCase):
    def setUp(self):
        work = tempfile.TemporaryDirectory()
        self.addCleanup(work.cleanup)
        self.root = Path(work.name)
        self.source = self.root / "cold" / "Debug-iphonesimulator"
        self.destination = self.root / "different" / "Debug-iphonesimulator"
        self.entry = self.root / "entry"
        self.key = "b" * 64
        for name in cache.FILES:
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(name.encode())
        (self.source / "Beid.app").mkdir()

    def test_fresh_products_only_receive_export(self):
        cache.snapshot(self.source, self.entry, self.key)
        cache.install(self.entry, self.destination, self.key)
        self.assertEqual({str(p.relative_to(self.destination)) for p in self.destination.rglob("*")
                          if p.is_file()}, cache.FILES)
        for name in cache.FILES:
            self.assertEqual((self.destination / name).read_bytes(), name.encode())

    def test_corrupt_or_different_key_never_changes_products(self):
        cache.snapshot(self.source, self.entry, self.key)
        with self.assertRaises(ValueError):
            cache.install(self.entry, self.destination, "c" * 64)
        (self.entry / "products/libBeidSharedKit.a").write_bytes(b"changed")
        with self.assertRaises(ValueError):
            cache.install(self.entry, self.destination, self.key)
        self.assertFalse(self.destination.exists())

    def test_reject_missing_and_unexpected_module_members(self):
        module = self.source / "KotlinRuntime"
        (module / "KotlinBase.h").unlink()
        with self.assertRaises(ValueError):
            cache.snapshot(self.source, self.entry, self.key)
        (module / "KotlinBase.h").write_bytes(b"header")
        (module / "unexpected").write_bytes(b"extra")
        with self.assertRaises(ValueError):
            cache.snapshot(self.source, self.entry, self.key)

    def test_reject_linked_inputs_and_occupied_destination(self):
        archive = self.source / "libBeidSharedKit.a"
        archive.unlink()
        archive.symlink_to(self.source / "KotlinRuntime/KotlinBase.h")
        with self.assertRaises(ValueError):
            cache.snapshot(self.source, self.entry, self.key)
        archive.unlink()
        archive.write_bytes(b"archive")
        cache.snapshot(self.source, self.entry, self.key)
        self.destination.mkdir(parents=True)
        (self.destination / "KotlinRuntime").symlink_to(self.source / "KotlinRuntime")
        with self.assertRaises(ValueError):
            cache.install(self.entry, self.destination, self.key)
        self.assertFalse((self.destination / "libBeidSharedKit.a").exists())


class ExportKeyTests(unittest.TestCase):
    def test_build_inputs_include_app_configuration_but_allow_ui_only_reuse(self):
        from scripts.ios_swift_export_key import tracked_input
        for name in ("shared/src/commonMain/kotlin/Foo.kt", "android/app/build.gradle.kts",
                     "android/version.properties", "android/gradle/wrapper/gradle-wrapper.jar",
                     "future/build-logic/src/Plugin.kt", "other/gradle.lockfile", "ios/project.yml",
                     ".github/actions/ios-swift-export/action.yml", "scripts/ios_swift_export_key.py"):
            self.assertTrue(tracked_input(name), name)
        self.assertFalse(tracked_input("ios/Beid/Home.swift"))

    def test_toolchain_ignores_rollout_version_but_detects_changed_compiler(self):
        import os
        from unittest.mock import patch
        from scripts import ios_swift_export_key as key

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for name in ("bin/java", "lib/modules", "lib/server/libjvm.dylib", "SDKSettings.json",
                         "swiftc", "swift-frontend", "clang", "ld", "libtool"):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(name.encode())

            def tool_command(*args):
                if args[-1] == "--show-sdk-path":
                    return os.fsencode(root)
                if args[-2] == "--find":
                    return os.fsencode(root / args[-1])
                if args[-2:] == ("clang", "--version"):
                    return b"clang 1\nInstalledDir: /runner/" + os.fsencode(os.environ["ImageVersion"])
                return b"same toolchain"

            self.addCleanup(key.content.cache_clear)
            with patch.object(key, "command", side_effect=tool_command), \
                 patch.object(key.subprocess, "check_output", return_value=b"Java 17"), \
                 patch.dict(os.environ, {"ImageOS": "xcode-27-arm64", "ImageVersion": "first"}):
                first = key.host_toolchain(root)
                with patch.dict(os.environ, {"ImageVersion": "second"}):
                    self.assertEqual(first, key.host_toolchain(root))
                    (root / "clang").write_bytes(b"changed compiler")
                    key.content.cache_clear()
                    self.assertNotEqual(first, key.host_toolchain(root))

    def test_key_is_relocatable_and_sensitive_to_source_dependencies_and_image(self):
        import json
        import subprocess
        from scripts.ios_swift_export_key import cache_key, content
        with tempfile.TemporaryDirectory() as temp:
            def make(root, *, source=b"export", library=b"klib", image="image-1"):
                shared = root / "shared"
                shared.mkdir(parents=True)
                (shared / "Api.kt").write_bytes(source)
                subprocess.run(["git", "init", "-q", str(root)], check=True)
                subprocess.run(["git", "-C", str(root), "add", "shared"], check=True)
                inputs = root / "inputs.json"
                dependency = root / "coroutines.klib"
                dependency.write_bytes(library)
                inputs.write_text(json.dumps([["compile", "coroutines:1", dependency.name, str(dependency)]]))
                tools = root / "native"
                for name in ["libffi-host", "llvm-host"]:
                    (tools / name).mkdir(parents=True)
                    (tools / name / "input").write_bytes(b"tool")
                content.cache_clear()
                return cache_key(root, inputs, tools, [image])
            root = Path(temp)
            initial = make(root / "a")
            self.assertEqual(initial, make(root / "b"))
            self.assertNotEqual(initial, make(root / "c", source=b"changed"))
            self.assertNotEqual(initial, make(root / "d", library=b"new"))
            self.assertNotEqual(initial, make(root / "e", image="image-2"))
