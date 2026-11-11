"""Each app platform keeps its version in exactly one file.

A version bump must be a one-file edit: ``ios/Version.xcconfig`` for iOS and
``android/version.properties`` for Android. A second copy fails silently rather
than loudly: a target-level ``MARKETING_VERSION`` in ``ios/project.yml`` or in
the generated project wins over the xcconfig, and a literal ``versionName`` in
Gradle turns the properties file into a dead letter. These tests fail when
either happens.
"""

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
IOS_VERSION = REPO_ROOT / "ios/Version.xcconfig"
IOS_SPEC = REPO_ROOT / "ios/project.yml"
IOS_PROJECT = REPO_ROOT / "ios/Beid.xcodeproj/project.pbxproj"
ANDROID_VERSION = REPO_ROOT / "android/version.properties"
ANDROID_GRADLE = REPO_ROOT / "android/app/build.gradle.kts"

IOS_KEYS = ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION")


class IosVersionFileTest(unittest.TestCase):
    def test_the_xcconfig_sets_each_key_once(self) -> None:
        body = IOS_VERSION.read_text(encoding="utf-8")
        for key in IOS_KEYS:
            with self.subTest(key=key):
                self.assertEqual(len(re.findall(rf"(?m)^{key} = \S+$", body)), 1)

    def test_no_target_sets_the_version_itself(self) -> None:
        """Only $(MARKETING_VERSION)-style references may remain elsewhere."""
        for path in (IOS_SPEC, IOS_PROJECT):
            body = path.read_text(encoding="utf-8")
            for key in IOS_KEYS:
                with self.subTest(file=path.name, key=key):
                    self.assertNotRegex(body, rf"(?m)^\s*{key}\s*[:=]")

    def test_every_build_configuration_is_based_on_the_xcconfig(self) -> None:
        spec = IOS_SPEC.read_text(encoding="utf-8")
        self.assertRegex(
            spec,
            r"(?m)^configFiles:\n  Debug: Version\.xcconfig\n  Release: Version\.xcconfig$",
        )
        project = IOS_PROJECT.read_text(encoding="utf-8")
        based = re.findall(
            r"baseConfigurationReference = [0-9A-F]{24} /\* Version\.xcconfig \*/;", project
        )
        self.assertEqual(len(based), 2, "the project's Debug and Release configurations")


class AndroidVersionFileTest(unittest.TestCase):
    def test_the_properties_file_sets_each_key_once(self) -> None:
        body = ANDROID_VERSION.read_text(encoding="utf-8")
        self.assertEqual(len(re.findall(r"(?m)^versionName=\S+$", body)), 1)
        self.assertEqual(len(re.findall(r"(?m)^versionCode=[1-9][0-9]*$", body)), 1)

    def test_gradle_reads_the_file_and_sets_no_literal(self) -> None:
        body = ANDROID_GRADLE.read_text(encoding="utf-8")
        self.assertIn('file("version.properties")', body)
        self.assertIn('versionName = appVersionValue("versionName")', body)
        self.assertIn('versionCode = appVersionValue("versionCode").toInt()', body)
        self.assertNotRegex(body, r'(?m)^\s*versionName\s*=\s*"')
        self.assertNotRegex(body, r"(?m)^\s*versionCode\s*=\s*\d")


if __name__ == "__main__":
    unittest.main()
