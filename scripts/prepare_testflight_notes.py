#!/usr/bin/env python3
"""Turn what_to_test.json / release_notes.json into per-store note files.

One formatter serves all three delivery paths (beid#503); there is deliberately
no second one.

Each entry ``{"language": "en-US", "text": "..."}`` becomes:

* ``--output-dir/WhatToTest.<language>.txt`` — the layout Xcode Cloud picks up
  automatically from ``ios/TestFlight/`` next to ``Beid.xcodeproj`` during the
  ci_post_xcodebuild phase, and the same text the temporary ``emi`` lane sends
  to the App Store Connect API as a build's ``whatsNew``.
* ``--play-output-dir/whatsnew-<language>`` — the layout
  ``r0adkll/upload-google-play`` reads for its ``whatsNewDirectory`` input. Its
  ``src/whatsnew.ts`` takes the language from the *filename* and uploads the
  file's bytes verbatim, so the character limit has to be applied here.

**The 500-character clip is Play-only and that asymmetry is load-bearing.**
Google Play rejects a release note longer than 500 characters; TestFlight
accepts far more. Clipping the TestFlight text to Play's limit would silently
shorten what iOS testers read in order to satisfy a limit that does not apply
to them.

``--platform`` resolves which source file a lane reads, so the preference lives
in one tested place instead of in each of the three shell callers.
"""
import argparse
import json
import sys
from pathlib import Path
from typing import Dict, List, Optional, Sequence

# Google Play's per-locale release-note limit. The upload action does not check
# it; the Play API rejects the edit, which would fail a job that has already
# uploaded the bundle.
PLAY_NOTE_LIMIT = 500

# Preferred source first, shared fallback second.
PLATFORM_SOURCES: Dict[str, Sequence[str]] = {
    "ios": ("what_to_test.ios.json", "what_to_test.json"),
    "android": ("what_to_test.android.json", "what_to_test.json"),
}


class NoSourceError(FileNotFoundError):
    """No candidate source file exists for the requested platform."""


def resolve_source(platform: str, repo_root: Path) -> Path:
    """Return the note file `platform` should publish, preferring its own.

    Raises NoSourceError naming every candidate, so a lane that finds nothing
    says which files it looked for rather than failing on a bare path.
    """
    candidates = [repo_root / name for name in PLATFORM_SOURCES[platform]]
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    raise NoSourceError(
        f"no note source for platform '{platform}'; looked for: "
        + ", ".join(str(candidate) for candidate in candidates)
    )


def load_notes(source: Path, skip_empty: bool = False) -> List[Dict[str, str]]:
    """Parse `source` into `{language, text}` entries.

    Structural defects (not an array, an entry that is not an object, a missing
    or non-string language) are always fatal: they mean the file is malformed,
    which no lane can act on.

    An entry whose *text* is blank is different — it is a well-formed file that
    simply has nothing to say for that locale. `skip_empty` chooses which of the
    two readings applies. Delivery lanes pass it and skip that locale with a log
    line, because refusing to publish is better than failing a job that has
    already uploaded a binary. PR CI does not pass it, so an accidentally
    emptied note still turns a pull request red before it can ship.
    """
    data = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(data, list):
        raise ValueError(f"{source} must contain an array")

    notes: List[Dict[str, str]] = []
    for index, item in enumerate(data, start=1):
        if not isinstance(item, dict):
            raise ValueError(f"{source} entry {index} must be an object")
        language = item.get("language")
        text = item.get("text")
        if not isinstance(language, str) or not language.strip():
            raise ValueError(f"{source} entry {index} is missing language")
        if not isinstance(text, str) or not text.strip():
            if skip_empty:
                print(
                    f"note: {source} entry {index} "
                    f"({language.strip() if isinstance(language, str) else '?'}) "
                    "has no text; skipping publication for that locale."
                )
                continue
            raise ValueError(f"{source} entry {index} is missing text")
        notes.append({"language": language.strip(), "text": text.strip()})
    return notes


def write_testflight_notes(notes: List[Dict[str, str]], output_dir: Path) -> None:
    """Write WhatToTest.<language>.txt files, uncut."""
    output_dir.mkdir(parents=True, exist_ok=True)
    for note in notes:
        output = output_dir / f"WhatToTest.{note['language']}.txt"
        output.write_text(note["text"] + "\n", encoding="utf-8")


def write_play_notes(notes: List[Dict[str, str]], output_dir: Path) -> None:
    """Write whatsnew-<language> files, clipped to Play's limit.

    A clip is announced with both lengths, because a note silently losing its
    last sentences is the failure this reports.
    """
    output_dir.mkdir(parents=True, exist_ok=True)
    for note in notes:
        text = note["text"]
        if len(text) > PLAY_NOTE_LIMIT:
            print(
                f"note: {note['language']} release note is {len(text)} characters; "
                f"truncating to Google Play's {PLAY_NOTE_LIMIT}-character limit."
            )
            text = text[:PLAY_NOTE_LIMIT]
        # No trailing newline: the action uploads these bytes verbatim as the
        # release note, and a newline would both show up in Play and count
        # against the limit.
        (output_dir / f"whatsnew-{note['language']}").write_text(text, encoding="utf-8")


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    source_group = parser.add_mutually_exclusive_group(required=True)
    source_group.add_argument(
        "--source",
        type=Path,
        help="Explicit note file. Use this when the caller already knows which "
        "file it wants, e.g. release_notes.json on a release branch.",
    )
    source_group.add_argument(
        "--platform",
        choices=sorted(PLATFORM_SOURCES),
        help="Resolve the source by platform preference: what_to_test.<platform>.json "
        "when it exists, otherwise what_to_test.json.",
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path.cwd(),
        help="Directory --platform resolves note files against (default: cwd).",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        help="Write WhatToTest.<language>.txt here (TestFlight layout).",
    )
    parser.add_argument(
        "--play-output-dir",
        type=Path,
        help="Write whatsnew-<language> here (Google Play whatsNewDirectory layout).",
    )
    parser.add_argument(
        "--skip-empty",
        action="store_true",
        help="Skip locales whose text is blank instead of failing. Delivery lanes "
        "pass this; PR CI does not.",
    )
    parser.add_argument(
        "--missing-ok",
        action="store_true",
        help="Warn and succeed when no source file exists at all, instead of failing. "
        "Build hooks pass this so a repository without note files still builds; it "
        "keeps the candidate list here rather than duplicating it in each caller.",
    )
    args = parser.parse_args(argv)
    if args.output_dir is None and args.play_output_dir is None:
        parser.error("at least one of --output-dir or --play-output-dir is required")
    return args


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)

    try:
        if args.source is not None:
            source = args.source
            if not source.is_file():
                raise NoSourceError(f"note source {source} does not exist")
        else:
            source = resolve_source(args.platform, args.repo_root)
    except NoSourceError as error:
        if not args.missing_ok:
            raise
        print(f"warning: {error}; skipping note generation.", file=sys.stderr)
        return 0

    print(f"Reading TestFlight/Play notes from {source}")

    notes = load_notes(source, skip_empty=args.skip_empty)
    if not notes:
        print(f"note: {source} has no publishable text; skipping note generation.")
        return 0

    if args.output_dir is not None:
        write_testflight_notes(notes, args.output_dir)
    if args.play_output_dir is not None:
        write_play_notes(notes, args.play_output_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
