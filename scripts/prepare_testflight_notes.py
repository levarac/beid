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
from typing import Dict, List


def load_notes(source: Path) -> List[Dict[str, str]]:
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
            raise ValueError(f"{source} entry {index} is missing text")
        notes.append({"language": language.strip(), "text": text.strip()})
    return notes


def write_testflight_notes(notes: List[Dict[str, str]], output_dir: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    for note in notes:
        output = output_dir / f"WhatToTest.{note['language']}.txt"
        output.write_text(note["text"] + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()

    notes = load_notes(args.source)
    write_testflight_notes(notes, args.output_dir)


if __name__ == "__main__":
    main()
