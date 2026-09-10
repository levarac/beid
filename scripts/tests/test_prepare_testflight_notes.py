"""Unit tests for the shared note formatter (beid#503, acceptance criterion 2).

Three behaviours are pinned here because each one, when wrong, is invisible in
a green delivery: a lane reading the wrong source file, a Play note silently
losing its tail, and a blank note either failing a delivery or being published
as nothing.

The truncation asymmetry gets a dedicated test. Clipping is correct for Google
Play, whose API rejects a release note over 500 characters, and *wrong* for
TestFlight, which accepts far more — so a single shared clip would quietly
shorten what iOS testers read to satisfy a limit that is not theirs.
"""

import io
import json
import sys
import unittest
from contextlib import redirect_stdout, redirect_stderr
from pathlib import Path
from tempfile import TemporaryDirectory

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import prepare_testflight_notes as notes  # noqa: E402


def write_json(path: Path, entries) -> None:
    path.write_text(json.dumps(entries), encoding="utf-8")


class SourceResolutionTest(unittest.TestCase):
    """The platform preference lives here, so all three lanes share one answer."""

    def test_ios_prefers_its_own_file(self) -> None:
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_json(root / "what_to_test.json", [{"language": "en-US", "text": "shared"}])
            write_json(root / "what_to_test.ios.json", [{"language": "en-US", "text": "ios"}])

            self.assertEqual(
                notes.resolve_source("ios", root), root / "what_to_test.ios.json"
            )

    def test_android_prefers_its_own_file(self) -> None:
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_json(root / "what_to_test.json", [{"language": "en-US", "text": "shared"}])
            write_json(root / "what_to_test.android.json", [{"language": "en-US", "text": "a"}])

            self.assertEqual(
                notes.resolve_source("android", root), root / "what_to_test.android.json"
            )

    def test_each_platform_falls_back_to_the_shared_file(self) -> None:
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_json(root / "what_to_test.json", [{"language": "en-US", "text": "shared"}])

            for platform in ("ios", "android"):
                with self.subTest(platform=platform):
                    self.assertEqual(
                        notes.resolve_source(platform, root), root / "what_to_test.json"
                    )

    def test_ios_does_not_read_the_android_file(self) -> None:
        """The two platform files are not interchangeable fallbacks for each other."""
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_json(root / "what_to_test.android.json", [{"language": "en-US", "text": "a"}])

            with self.assertRaises(notes.NoSourceError):
                notes.resolve_source("ios", root)

    def test_missing_source_names_every_candidate(self) -> None:
        with TemporaryDirectory() as tmp:
            with self.assertRaises(notes.NoSourceError) as caught:
                notes.resolve_source("ios", Path(tmp))

            message = str(caught.exception)
            self.assertIn("what_to_test.ios.json", message)
            self.assertIn("what_to_test.json", message)


class LocaleExpansionTest(unittest.TestCase):
    def test_one_file_per_locale_in_each_layout(self) -> None:
        entries = [
            {"language": "en-US", "text": "english"},
            {"language": "ja", "text": "japanese"},
        ]
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_json(root / "what_to_test.json", entries)
            loaded = notes.load_notes(root / "what_to_test.json")

            notes.write_testflight_notes(loaded, root / "tf")
            with redirect_stdout(io.StringIO()):
                notes.write_play_notes(loaded, root / "play")

            self.assertEqual(
                sorted(p.name for p in (root / "tf").iterdir()),
                ["WhatToTest.en-US.txt", "WhatToTest.ja.txt"],
            )
            self.assertEqual(
                sorted(p.name for p in (root / "play").iterdir()),
                ["whatsnew-en-US", "whatsnew-ja"],
            )
            self.assertEqual(
                (root / "play" / "whatsnew-en-US").read_text(encoding="utf-8"), "english"
            )


class PlayTruncationTest(unittest.TestCase):
    def test_a_note_at_the_limit_is_untouched(self) -> None:
        text = "x" * notes.PLAY_NOTE_LIMIT
        with TemporaryDirectory() as tmp:
            out = Path(tmp) / "play"
            stdout = io.StringIO()
            with redirect_stdout(stdout):
                notes.write_play_notes([{"language": "en-US", "text": text}], out)

            self.assertEqual((out / "whatsnew-en-US").read_text(encoding="utf-8"), text)
            self.assertNotIn("truncating", stdout.getvalue())

    def test_one_character_over_the_limit_is_clipped_and_announced(self) -> None:
        text = "y" * (notes.PLAY_NOTE_LIMIT + 1)
        with TemporaryDirectory() as tmp:
            out = Path(tmp) / "play"
            stdout = io.StringIO()
            with redirect_stdout(stdout):
                notes.write_play_notes([{"language": "en-US", "text": text}], out)

            written = (out / "whatsnew-en-US").read_text(encoding="utf-8")
            self.assertEqual(len(written), notes.PLAY_NOTE_LIMIT)
            logged = stdout.getvalue()
            self.assertIn(str(notes.PLAY_NOTE_LIMIT + 1), logged)
            self.assertIn(str(notes.PLAY_NOTE_LIMIT), logged)
            self.assertIn("en-US", logged)

    def test_the_testflight_layout_is_not_clipped_at_plays_limit(self) -> None:
        """The asymmetry itself, stated as a test.

        Deleting the clip from write_play_notes turns the test above red;
        copying it into write_testflight_notes turns this one red.
        """
        text = "z" * (notes.PLAY_NOTE_LIMIT + 300)
        with TemporaryDirectory() as tmp:
            out = Path(tmp) / "tf"
            notes.write_testflight_notes([{"language": "en-US", "text": text}], out)

            self.assertEqual(
                (out / "WhatToTest.en-US.txt").read_text(encoding="utf-8"), text + "\n"
            )


class EmptyTextTest(unittest.TestCase):
    def test_a_delivery_lane_skips_a_blank_locale_and_says_so(self) -> None:
        entries = [
            {"language": "en-US", "text": "kept"},
            {"language": "ja", "text": "   "},
        ]
        with TemporaryDirectory() as tmp:
            source = Path(tmp) / "what_to_test.json"
            write_json(source, entries)

            stdout = io.StringIO()
            with redirect_stdout(stdout):
                loaded = notes.load_notes(source, skip_empty=True)

            self.assertEqual([note["language"] for note in loaded], ["en-US"])
            self.assertIn("skipping", stdout.getvalue())
            self.assertIn("ja", stdout.getvalue())

    def test_pr_ci_still_fails_on_a_blank_locale(self) -> None:
        """Without --skip-empty the blank note is fatal, as it is on main today.

        This is the half that keeps `Validate TestFlight note structure` in
        pr-ci.yml meaningful: skip-and-log is what a delivery lane needs *after*
        a binary is already uploaded, not what a pull request needs.
        """
        with TemporaryDirectory() as tmp:
            source = Path(tmp) / "what_to_test.json"
            write_json(source, [{"language": "en-US", "text": ""}])

            with self.assertRaises(ValueError):
                notes.load_notes(source)

    def test_an_all_blank_file_publishes_nothing_and_succeeds(self) -> None:
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_json(root / "what_to_test.json", [{"language": "en-US", "text": " "}])

            stdout = io.StringIO()
            with redirect_stdout(stdout):
                code = notes.main(
                    [
                        "--platform",
                        "ios",
                        "--repo-root",
                        str(root),
                        "--skip-empty",
                        "--output-dir",
                        str(root / "tf"),
                        "--play-output-dir",
                        str(root / "play"),
                    ]
                )

            self.assertEqual(code, 0)
            self.assertIn("no publishable text", stdout.getvalue())
            self.assertFalse((root / "tf").exists())
            self.assertFalse((root / "play").exists())

    def test_structural_damage_stays_fatal_even_with_skip_empty(self) -> None:
        """--skip-empty forgives an empty note, never a malformed file."""
        with TemporaryDirectory() as tmp:
            source = Path(tmp) / "what_to_test.json"
            source.write_text(json.dumps({"language": "en-US"}), encoding="utf-8")

            with self.assertRaises(ValueError):
                notes.load_notes(source, skip_empty=True)


class MissingSourceTest(unittest.TestCase):
    def test_missing_ok_warns_and_succeeds(self) -> None:
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            stderr = io.StringIO()
            with redirect_stderr(stderr), redirect_stdout(io.StringIO()):
                code = notes.main(
                    ["--platform", "ios", "--repo-root", str(root),
                     "--missing-ok", "--output-dir", str(root / "tf")]
                )

            self.assertEqual(code, 0)
            self.assertIn("skipping note generation", stderr.getvalue())

    def test_without_missing_ok_a_missing_source_fails(self) -> None:
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            with self.assertRaises(notes.NoSourceError):
                notes.main(["--platform", "ios", "--repo-root", str(root),
                            "--output-dir", str(root / "tf")])


class ArgumentContractTest(unittest.TestCase):
    def test_an_output_destination_is_required(self) -> None:
        with TemporaryDirectory() as tmp:
            with self.assertRaises(SystemExit), redirect_stderr(io.StringIO()):
                notes.parse_args(["--platform", "ios", "--repo-root", tmp])

    def test_source_and_platform_are_mutually_exclusive(self) -> None:
        with self.assertRaises(SystemExit), redirect_stderr(io.StringIO()):
            notes.parse_args(
                ["--source", "a.json", "--platform", "ios", "--output-dir", "out"]
            )


if __name__ == "__main__":
    unittest.main()
