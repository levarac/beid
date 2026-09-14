import unittest

from scripts.ci_change_filter import classify


class CIChangeFilterTests(unittest.TestCase):
    def test_docs_only_skips_expensive_lanes_but_keeps_sanity(self):
        self.assertEqual(
            classify(["README.md", "docs/ci.md"]),
            {"android": False, "lint": False, "sanity": True, "error": False},
        )

    def test_android_change_runs_android_only(self):
        result = classify(["android/app/src/main/Foo.kt"])
        self.assertEqual(result["android"], True)
        self.assertEqual(result["lint"], False)
        self.assertEqual(result["sanity"], True)

    def test_shared_change_runs_both_product_lanes(self):
        result = classify(["shared/src/commonMain/kotlin/Policy.kt"])
        self.assertEqual(result["android"], True)
        self.assertEqual(result["lint"], True)

    def test_workflow_and_dependency_changes_run_everything(self):
        for path in [
            ".github/workflows/pr-ci.yml",
            "android/build.gradle.kts",
            "ios/Package.resolved",
            "gradle/libs.versions.toml",
        ]:
            result = classify([path])
            self.assertEqual(result, {"android": True, "lint": True, "sanity": True, "error": False})

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
        self.assertEqual(classify([]), {"android": True, "lint": True, "sanity": True, "error": True})


if __name__ == "__main__":
    unittest.main()
