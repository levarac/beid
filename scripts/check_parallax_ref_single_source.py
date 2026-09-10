#!/usr/bin/env python3
"""Fail if the pinned Parallax commit appears anywhere but its canonical source.

`clone_parallax_pinned.sh` says the point of the pin is that there is exactly
one copy of the ref. What it actually enforces is narrower: that the file it
reads contains exactly one `EXPECTED_PARALLAX_REF` assignment. A second copy in
a workflow YAML, another constant, a script, or a document passes that check
untouched (beid#478). This script checks the stated property instead: the
pinned value occurs in the canonical file and nowhere else in the repository.

Both the ref and the canonical path come from `clone_parallax_pinned.sh`
(`--print-ref`, `--print-source`). Neither is written down here on purpose: a
checker that restated either one would be the second source of truth it exists
to forbid.

The convention this enforces, and which makes the rule true rather than
merely enforced: **a full 40-hex ref is a declaration; a mention of a ref in
prose is written in abbreviated form.** A dated record ("the comparison passed
against 6fe165f") is evidence, not a source of truth, and an abbreviated sha
still identifies the commit uniquely -- so the record loses nothing, while
"exactly one full 40-hex, in the canonical file" becomes true by convention
instead of by exception. Do not "helpfully" expand an abbreviated ref in a
record back to the full hash.

**Full 40-hex only. Abbreviated prefixes are deliberately not scanned.**
`scripts/tests/test_parallax_ci_wiring.py` asserts that a short sha is refused
as a pin, and its fixture is a 7-hex prefix of a *superseded* ref. That fixture
is about the *format* -- any 7-hex string would serve -- so it is not a copy of
the pin and must not be bumped when the pin moves; it will look stale forever
and be correct. Scanning prefixes would fail on it from day one. Catching
abbreviated copies too would need an allowlist for that file, and an allowlist
is the thing that rots: it goes stale silently, whereas this scan's answer is
recomputed from the pin every run. The trade is deliberate -- an abbreviated
second copy elsewhere is not caught.

Scope is `git ls-files`: tracked files only, which excludes `.git` and build
output without maintaining a list of generated directories.
"""

import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
PIN_SCRIPT = REPO_ROOT / "scripts" / "clone_parallax_pinned.sh"


def _ask_pin_script(flag: str) -> str:
    result = subprocess.run(
        ["bash", str(PIN_SCRIPT), flag],
        capture_output=True,
        text=True,
        cwd=REPO_ROOT,
    )
    if result.returncode != 0:
        raise SystemExit(
            f"check_parallax_ref_single_source: {PIN_SCRIPT.name} {flag} failed "
            f"({result.returncode}): {result.stderr.strip()}"
        )
    return result.stdout.strip()


def tracked_files(repo_root: Path) -> list[Path]:
    result = subprocess.run(
        ["git", "ls-files", "-z"],
        capture_output=True,
        cwd=repo_root,
        check=True,
    )
    return [
        repo_root / name.decode("utf-8")
        for name in result.stdout.split(b"\0")
        if name
    ]


def occurrences(repo_root: Path, ref: str) -> list[tuple[Path, int, str]]:
    """Every tracked line containing the full pinned ref, as (path, lineno, line)."""
    needle = ref.encode("ascii")
    found = []
    for path in tracked_files(repo_root):
        try:
            blob = path.read_bytes()
        except (OSError, IsADirectoryError):
            # A tracked path that cannot be read here (submodule, broken symlink)
            # cannot contain a copy we could act on either.
            continue
        if needle not in blob:
            continue
        for lineno, line in enumerate(blob.split(b"\n"), start=1):
            if needle in line:
                found.append(
                    (path, lineno, line.decode("utf-8", errors="replace").strip())
                )
    return found


def main() -> int:
    ref = _ask_pin_script("--print-ref")
    canonical = Path(_ask_pin_script("--print-source")).resolve()

    found = occurrences(REPO_ROOT, ref)
    canonical_hits = [hit for hit in found if hit[0].resolve() == canonical]
    strays = [hit for hit in found if hit[0].resolve() != canonical]

    if not canonical_hits:
        print(
            "check_parallax_ref_single_source: the pinned ref does not appear in its "
            f"own canonical source.\n  ref:       {ref}\n  canonical: "
            f"{canonical.relative_to(REPO_ROOT)}\n"
            "This means the scan is not looking where the pin lives, so a zero "
            "stray count below would be meaningless.",
            file=sys.stderr,
        )
        return 1

    if strays:
        print(
            f"check_parallax_ref_single_source: the pinned Parallax ref is copied "
            f"outside its canonical source.\n\n  ref:       {ref}\n  canonical: "
            f"{canonical.relative_to(REPO_ROOT)}\n\n"
            f"{len(strays)} stray copy/copies:",
            file=sys.stderr,
        )
        for path, lineno, line in strays:
            print(f"  {path.relative_to(REPO_ROOT)}:{lineno}: {line}", file=sys.stderr)
        print(
            "\nThe pin must have exactly one source of truth.\n"
            "Convention: a full 40-hex ref is a DECLARATION; a mention in prose is "
            "written ABBREVIATED.\n"
            "  - a second declaration -> remove it and read the canonical one\n"
            "  - a dated record or narrative mention -> abbreviate it "
            f"(`{ref[:7]}` identifies the commit uniquely)\n"
            "A record is evidence, not a source of truth: abbreviating keeps the "
            "fact, expanding it later re-creates this failure.",
            file=sys.stderr,
        )
        return 1

    print(
        f"OK: the pinned Parallax ref appears only in "
        f"{canonical.relative_to(REPO_ROOT)} "
        f"({len(canonical_hits)} line(s) checked, full 40-hex only)."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
