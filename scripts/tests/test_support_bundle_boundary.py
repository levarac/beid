"""Source boundary plus shared authority for the opt-in support exporter.

Behavior and actual share bytes are covered in native and common tests.
This gate keeps exporters disconnected from stores and generic object dumps.
"""

from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SupportBundleBoundaryTest(unittest.TestCase):
    def test_native_adapters_use_shared_and_cannot_import_stores(self):
        adapters = [
            ROOT / "ios/Beid/Support/SupportDiagnostics.swift",
            ROOT / "android/app/src/main/kotlin/org/levarac/beid/support/SupportDiagnostics.kt",
        ]
        for path in adapters:
            with self.subTest(path=path):
                self.assertTrue(path.is_file(), "Missing native support adapter")
                source = path.read_text()
                self.assertIn("SupportBundleRecorder", source)
                self.assertIn("recorder.exportJson(", source)
                for forbidden in (
                    "observedRpids", "ProofStore", "ProofRecordStore", "Ledger",
                    "Keychain", "KeyStore", "FileManager", "URLSession",
                    "JSONObject", "JSONSerialization", "Gson", "state.toString()",
                    "String(describing:", "localizedDescription", ".persistence.",
                    "eventCode", "eventId", "SensingCoordinator", "Barnard",
                ):
                    self.assertNotIn(forbidden, source)
                imports = {line.strip() for line in source.splitlines() if line.startswith("import ")}
                if path.suffix == ".swift":
                    self.assertEqual(imports, {"import BeidSharedKit", "import Combine", "import Foundation"})
                else:
                    self.assertEqual(imports, {
                        "import androidx.lifecycle.ViewModel",
                        "import org.levarac.beid.BuildConfig",
                        "import org.levarac.beid.sensing.EventJoinUiState",
                        "import org.levarac.beid.sensing.ScanPhase",
                        "import org.levarac.beid.shared.event.eventJoinFailureReasonKey",
                        "import org.levarac.beid.shared.support.SupportBundleRecorder",
                        "import org.levarac.beid.shared.support.SupportFailure",
                        "import org.levarac.beid.shared.support.SupportPlatform",
                        "import org.levarac.beid.shared.support.SupportState",
                        "import org.levarac.beid.shared.support.supportFailureForReasonKey",
                    })

    def test_account_actions_are_wired_to_the_shared_export(self):
        ios = (ROOT / "ios/Beid/Views/AccountSheetView.swift").read_text()
        android = (ROOT / "android/app/src/main/kotlin/org/levarac/beid/navigation/AppNavHost.kt").read_text()
        self.assertIn("coordinator.supportDiagnostics.exportJson()", ios)
        self.assertIn("supportDiagnostics.exportJson()", android)


if __name__ == "__main__":
    unittest.main()
