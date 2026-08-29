#!/usr/bin/env python3
"""Verify org.levarac:barnard resolved to what android/app/build.gradle.kts declares.

gh#110: a Barnard version bump once landed with a stale import that did not
match what the published artifact actually exposed, and a local
`assembleDebug passed` report was trusted without proving what the build
actually resolved against. This script reads a captured
`./gradlew :app:dependencyInsight --dependency barnard --configuration
debugRuntimeClasspath` log and cross-checks it against the declared
coordinate, so CI leaves machine-checkable evidence of what a build actually
resolved instead of only a human assertion that it built.

It intentionally checks three things, since a build can "succeed" while any
one of them silently changed what actually got used:
  1. the resolved version matches the declared `implementation(...)` coordinate
  2. resolution was not overridden by a `resolutionStrategy.force`
  3. resolution did not get substituted with a project/composite-build module,
     and no `mavenLocal()` repository is declared that could otherwise swap in
     a same-version-numbered but different artifact
"""
import argparse
import re
import sys
from pathlib import Path

DECLARED_RE = re.compile(r'implementation\("org\.levarac:barnard:([^"]+)"\)')
MAVEN_LOCAL_RE = re.compile(r"\bmavenLocal\s*\(")
FORCED_HEADER_RE = re.compile(r"^org\.levarac:barnard:\S+\s*\(forced\)\s*$")
TREE_CONTINUATION_RE = re.compile(r"^[\\+]---\s")

# The "> Task :app:dependencyInsight" console output includes classpath-tree
# lines such as (observed against Gradle 8.14 on this repo):
#   org.levarac:barnard:0.3.0                     requested == resolved
#   org.levarac:barnard:0.3.0 -> 0.2.0             resolution rewrote the version
#   org.levarac:barnard:0.3.0 -> project :shared   dependency substitution
# each immediately followed by a `\---`/`+---` classpath-tree continuation
# line — that pairing is what distinguishes a tree entry from the unrelated
# variant-attribute-table header line above it, which has the same shape.
TREE_ENTRY_RE = re.compile(
    r"^org\.levarac:barnard:(?P<requested>\S+?)(?:\s*->\s*(?P<resolved>\S+(?:\s+\S+)*))?$"
)


def declared_version(build_gradle_path):
    text = build_gradle_path.read_text(encoding="utf-8")
    match = DECLARED_RE.search(text)
    if not match:
        raise SystemExit(
            f'error: no org.levarac:barnard version declared via '
            f'implementation("org.levarac:barnard:X.Y.Z") in {build_gradle_path}'
        )
    return match.group(1)


def check_no_maven_local(gradle_files):
    for path in gradle_files:
        text = path.read_text(encoding="utf-8")
        if MAVEN_LOCAL_RE.search(text):
            raise SystemExit(
                f"error: {path} declares mavenLocal() — a local Maven override "
                "could silently swap in a different org.levarac:barnard artifact "
                "under the same version number than the published Maven Central "
                "release. Remove it."
            )


def find_dependency_insight_section(log_text):
    lines = log_text.splitlines()
    start = None
    for i, line in enumerate(lines):
        if line.strip() == "> Task :app:dependencyInsight":
            start = i + 1
            break
    if start is None:
        raise SystemExit(
            "error: dependency-insight log has no '> Task :app:dependencyInsight' "
            "line — was the task actually run (not skipped/cached) and captured "
            "into this log? Inspect the log."
        )
    end = len(lines)
    for i in range(start, len(lines)):
        if lines[i].startswith("> Task ") or lines[i].startswith("BUILD "):
            end = i
            break
    return lines[start:end]


def find_tree_entries(section_lines):
    """Return (requested, resolved) pairs from classpath-tree lines only."""
    entries = []
    for i, line in enumerate(section_lines):
        match = TREE_ENTRY_RE.match(line.strip())
        if not match:
            continue
        following = section_lines[i + 1].strip() if i + 1 < len(section_lines) else ""
        if not TREE_CONTINUATION_RE.match(following):
            continue  # variant-attribute-table header, not a classpath-tree entry
        requested = match.group("requested")
        resolved = match.group("resolved") or requested
        entries.append((requested, resolved))
    return entries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-gradle", required=True, type=Path)
    parser.add_argument("--settings-gradle", required=True, type=Path)
    parser.add_argument("--root-build-gradle", required=True, type=Path)
    parser.add_argument("--dependency-insight-log", required=True, type=Path)
    args = parser.parse_args()

    declared = declared_version(args.build_gradle)
    check_no_maven_local([args.build_gradle, args.settings_gradle, args.root_build_gradle])

    log_text = args.dependency_insight_log.read_text(encoding="utf-8")
    section = find_dependency_insight_section(log_text)

    if any(FORCED_HEADER_RE.match(line.strip()) for line in section):
        raise SystemExit(
            "error: org.levarac:barnard resolution is forced (a "
            "resolutionStrategy.force override is active on this configuration) "
            "— this can silently swap in a version other than the declared "
            "coordinate. Remove the force."
        )

    entries = find_tree_entries(section)
    if not entries:
        raise SystemExit(
            "error: could not find an 'org.levarac:barnard:...' classpath-tree "
            "entry in the dependencyInsight output — parser or task-invocation "
            "mismatch, inspect the log."
        )

    for requested, resolved in entries:
        if resolved.startswith("project "):
            raise SystemExit(
                f"error: org.levarac:barnard resolved to a project/composite-build "
                f"substitution ({resolved}), not the published Maven Central "
                "artifact. Remove the substitution."
            )
        if requested != declared:
            raise SystemExit(
                f"error: dependencyInsight requested coordinate version "
                f"{requested!r} does not match the version declared in "
                f"{args.build_gradle} ({declared!r}) — investigate before "
                "trusting this report."
            )
        if resolved != declared:
            raise SystemExit(
                f"error: org.levarac:barnard is declared as {declared} in "
                f"{args.build_gradle} but resolved to {resolved} — a transitive "
                "conflict, override, or substitution changed what this build "
                "actually used."
            )

    print(
        f"OK: org.levarac:barnard resolved to org.levarac:barnard:{declared} "
        "(external Maven Central module, no force override, no project/"
        "composite-build substitution, no mavenLocal() repository declared)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
