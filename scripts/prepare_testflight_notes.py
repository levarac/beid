#!/usr/bin/env python3
"""Convert what_to_test.json / release_notes.json into TestFlight note files.

Each entry `{"language": "en-US", "text": "..."}` becomes
`<output-dir>/WhatToTest.<language>.txt`, the layout Xcode Cloud picks up
automatically from ios/TestFlight/ next to Beid.xcodeproj during the
ci_post_xcodebuild phase.
"""
import argparse
import json
from pathlib import Path
import re
from typing import Dict, List


# Canonical ASC locale shape: a lowercase ISO 639 language followed by an
# optional title-case script and optional uppercase/numeric region.
LOCALE_PATTERN = re.compile(
    r"^[a-z]{2,3}(?:-[A-Z][a-z]{3})?(?:-(?:[A-Z]{2}|[0-9]{3}))?$"
)


def resolve_source(source: Path, fallback_source: Path | None = None) -> Path:
    if source.is_file():
        return source
    if fallback_source is not None and fallback_source.is_file():
        return fallback_source
    if fallback_source is None:
        raise FileNotFoundError(f"TestFlight note source not found: {source}")
    raise FileNotFoundError(
        f"TestFlight note sources not found: {source}, {fallback_source}"
    )


def load_notes(source: Path) -> List[Dict[str, str]]:
    data = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(data, list):
        raise ValueError(f"{source} must contain an array")
    if not data:
        raise ValueError(f"{source} must contain at least one note")

    notes: List[Dict[str, str]] = []
    seen_languages: set[str] = set()
    for index, item in enumerate(data, start=1):
        if not isinstance(item, dict):
            raise ValueError(f"{source} entry {index} must be an object")
        language = item.get("language")
        text = item.get("text")
        if not isinstance(language, str) or not language.strip():
            raise ValueError(f"{source} entry {index} is missing language")
        if not isinstance(text, str) or not text.strip():
            raise ValueError(f"{source} entry {index} is missing text")
        language = language.strip()
        if LOCALE_PATTERN.fullmatch(language) is None:
            raise ValueError(f"{source} entry {index} has invalid language {language!r}")
        if language in seen_languages:
            raise ValueError(f"{source} contains duplicate language {language!r}")
        seen_languages.add(language)
        notes.append({"language": language, "text": text.strip()})
    return notes


def write_testflight_notes(notes: List[Dict[str, str]], output_dir: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    for stale_note in output_dir.glob("WhatToTest.*.txt"):
        stale_note.unlink()
    for note in notes:
        output = output_dir / f"WhatToTest.{note['language']}.txt"
        output.write_text(note["text"] + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--fallback-source", type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()

    source = resolve_source(args.source, args.fallback_source)
    notes = load_notes(source)
    write_testflight_notes(notes, args.output_dir)
    print(f"Prepared {len(notes)} TestFlight note(s) from {source}")


if __name__ == "__main__":
    main()
