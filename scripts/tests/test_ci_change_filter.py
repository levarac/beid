import unittest

from scripts.ci_change_filter import classify


class CIChangeFilterTests(unittest.TestCase):
    def test_docs_only_skips_expensive_lanes_but_keeps_sanity(self):
        self.assertEqual(
            classify(["README.md", "docs/ci.md"]),
            {"android": False, "lint": False, "labcli": False, "sanity": True, "error": False, "ios": False},
        )

    def test_android_change_runs_android_only(self):
        result = classify(["android/app/src/main/Foo.kt"])
        self.assertEqual(result["android"], True)
        self.assertEqual(result["lint"], False)
        self.assertEqual(result["sanity"], True)

    def test_android_app_build_inputs_run_ios(self):
        for path in (
            "android/app/build.gradle.kts",
            "android/app/build.gradle",
            "android/app/settings.gradle.kts",
            "android/app/settings.gradle",
            "android/app/gradle.properties",
            "android/app/proguard-rules.pro",
            "android/app/config/inputs.json",
            "android/app/config/custom.gradle.kts",
            "android/app/config/custom.gradle",
            "android/app/buildSrc/src/main/kotlin/Plugin.kt",
            "android/app/build-logic/src/main/kotlin/Plugin.kt",
            "android/app/src/main/custom.gradle.kts",
            "android/app/src/main/custom.gradle",
            "android/app/src/main/gradle.properties",
            "android/app/src/buildSrc/src/main/kotlin/Plugin.kt",
            "android/app/src/build-logic/src/main/kotlin/Plugin.kt",
        ):
            with self.subTest(path=path):
                self.assertTrue(classify([path])["ios"])

    def test_android_app_sources_and_resources_skip_ios(self):
        for path in (
            "android/app/src/main/kotlin/org/levarac/beid/MainActivity.kt",
            "android/app/src/main/AndroidManifest.xml",
            "android/app/src/main/res/values/strings.xml",
            "android/app/src/test/kotlin/PolicyTest.kt",
            "android/app/src/androidTest/kotlin/DeviceTest.kt",
        ):
            with self.subTest(path=path):
                self.assertFalse(classify([path])["ios"])

    def test_shared_change_runs_both_product_lanes(self):
        result = classify(["shared/src/commonMain/kotlin/Policy.kt"])
        self.assertEqual(result["android"], True)
        self.assertEqual(result["lint"], True)

    def test_venue_gap_fixtures_run_android_and_ios(self):
        for name in ("valid.venue-bundle.cbor", "valid.venue-handoff.cbor"):
            with self.subTest(name=name):
                self.assertEqual(
                    classify([f"ios/BeidTests/Fixtures/venue-bundle-conformance/{name}"]),
                    {"android": True, "lint": True, "labcli": False, "sanity": True, "error": False, "ios": True},
                )

    def test_venue_full_schedule_fixtures_run_android_and_ios(self):
        for name in ("full-schedule.venue-bundle.hex", "full-schedule.venue-handoff.hex"):
            with self.subTest(name=name):
                self.assertEqual(
                    classify([f"ios/BeidTests/Fixtures/venue-bundle-conformance/{name}"]),
                    {"android": True, "lint": True, "labcli": False, "sanity": True, "error": False, "ios": True},
                )

    def test_other_ios_paths_still_skip_android(self):
        for path in (
            "ios/Beid/Sensing/VenueBundleVerification.swift",
            "ios/BeidTests/Fixtures/other/valid.venue-bundle.cbor",
            "ios/BeidTests/Fixtures/venue-bundle-conformance-other/valid.venue-bundle.cbor",
        ):
            with self.subTest(path=path):
                self.assertEqual(
                    classify([path]),
                    {"android": False, "lint": True, "labcli": False, "sanity": True, "error": False, "ios": True},
                )

    def test_workflow_and_dependency_changes_run_everything(self):
        for path in [
            ".github/workflows/pr-ci.yml",
            "android/build.gradle.kts",
            "ios/Package.resolved",
            "gradle/libs.versions.toml",
        ]:
            result = classify([path])
            self.assertEqual(
                result,
                {"android": True, "lint": True, "labcli": True, "sanity": True, "error": False, "ios": True},
            )

    def test_mixed_paths_are_union_of_relevant_lanes(self):
        result = classify(["android/app/Foo.kt", "ios/Beid/App.swift"])
        self.assertEqual(result["android"], True)
        self.assertEqual(result["lint"], True)
        self.assertEqual(result["sanity"], True)

    def test_rename_and_deletion_use_paths_and_unknown_fails_closed(self):
        self.assertEqual(classify(["android/old.kt", "android/new.kt"])["android"], True)
        self.assertEqual(classify(["ios/removed.swift"])["lint"], True)
        self.assertEqual(classify(["new-product-area/config.toml"])["error"], True)

    def test_missing_or_empty_input_fails_closed(self):
        self.assertEqual(
            classify([]),
            {"android": True, "lint": True, "labcli": True, "sanity": True, "error": True, "ios": True},
        )


    # The macOS lab CLI (beid#588). It is a standalone SwiftPM package that no
    # app target links, so the point of these is that a change there runs its
    # own macOS job and *not* the two expensive product lanes.
    def test_lab_cli_change_runs_only_its_own_job(self):
        self.assertEqual(
            classify(["tools/beid-lab-cli/Sources/BeidLabCliCore/LabLine.swift"]),
            {"android": False, "lint": False, "labcli": True, "sanity": True, "error": False, "ios": False},
        )

    def test_lab_cli_package_resolved_does_not_force_every_lane(self):
        # `Package.resolved` is in the force-all basename set because the iOS
        # app's pin is a delivery concern. This package's pin is not: nothing
        # links it, and `check_lab_cli_barnard_pin.py` verifies it in the
        # always-on sanity job. Without the exemption a one-line pin bump here
        # would run the Android build.
        self.assertEqual(
            classify(["tools/beid-lab-cli/Package.resolved"]),
            {"android": False, "lint": False, "labcli": True, "sanity": True, "error": False, "ios": False},
        )
        # The app's own pin is unaffected by that exemption.
        self.assertEqual(classify(["ios/Package.resolved"])["android"], True)

    def test_lab_cli_docs_need_no_build(self):
        self.assertEqual(
            classify(["tools/beid-lab-cli/README.md"]),
            {"android": False, "lint": False, "labcli": False, "sanity": True, "error": False, "ios": False},
        )

    def test_a_lab_cli_change_beside_a_product_change_runs_both(self):
        result = classify(
            ["tools/beid-lab-cli/Package.swift", "android/app/src/main/Foo.kt"]
        )
        self.assertEqual(result["labcli"], True)
        self.assertEqual(result["android"], True)
        self.assertEqual(result["lint"], False)
        self.assertEqual(result["error"], False)

    def test_another_tools_subdirectory_still_fails_closed(self):
        # The exemption is for this one package, not for `tools/` at large: a
        # future tool that nobody has classified must not inherit a cheap
        # classification it was never assessed for.
        result = classify(["tools/some-future-thing/main.swift"])
        self.assertEqual(result["error"], True)
        self.assertEqual(result["android"], True)

    def test_a_path_merely_starting_with_the_prefix_is_not_the_package(self):
        result = classify(["tools/beid-lab-cli-other/main.swift"])
        self.assertEqual(result["error"], True)

    def test_force_all_also_runs_the_lab_cli_job(self):
        # A workflow or scripts/ change can alter how the lab CLI is built or
        # checked, so the conservative branch stays conservative about it too.
        self.assertEqual(classify([".github/workflows/pr-ci.yml"])["labcli"], True)


if __name__ == "__main__":
    unittest.main()
