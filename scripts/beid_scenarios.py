#!/usr/bin/env python3
"""List beid's demo scenarios and launch one on a simulator or emulator.

beid#399: a developer should not have to remember the shape of
`-beid-demo-scenario` or `am start --es beid-demo-scenario` to see a scenario
running.

The shared fixture is the catalog source of truth. Platform enums retain their
public cases, while this command and host tests require their identifiers to
match the fixture. A unilateral platform addition therefore fails repository
sanity instead of becoming a third catalog to reconcile by hand.

**Why `run` refuses an unknown scenario instead of passing it through.** Both
apps deliberately fall back to `appReviewGolden` for an unrecognised value, so
that an App Review launch never lands on a blank screen. That forgiveness is
right for the app and wrong for a developer tool: a typo would launch a
different scenario than the one asked for and look like it worked. The refusal
here is the only place that mistake is visible.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "shared" / "src" / "commonTest" / "fixtures" / "demo-scenarios.txt"
IOS_SOURCE = ROOT / "ios" / "Beid" / "Models" / "DemoScenario.swift"
ANDROID_SOURCE = (
    ROOT / "android" / "app" / "src" / "main" / "kotlin" / "org" / "levarac" / "beid"
    / "scenario" / "AndroidDemoScenario.kt"
)

ANDROID_PACKAGE = "org.levarac.beid"
ANDROID_ACTIVITY = f"{ANDROID_PACKAGE}/.MainActivity"
IOS_BUNDLE_ID = "org.levarac.beid"

SCENARIO_ARG = "beid-demo-scenario"
SURFACE_ARG = "beid-demo-surface"
ANDROID_SURFACES = ("eventJoin", "records")

# iOS has no surface launch argument yet (beid#399, split out because wiring
# the records surface restructures a SwiftUI List that a UI test queries).
# Emitting `-beid-demo-surface` to iOS today would pass an argument nothing
# reads: it would look like a capability, and do nothing.
IOS_SURFACES: tuple[str, ...] = ()


def parse_ios_scenarios(text: str) -> list[str]:
    """Identifiers in `DemoScenario.swift`, in source order.

    Keyed on the `identifier:` label rather than the `allScenarios` array,
    because the array lists static property names while the strings that the
    launch argument actually matches live at the initialisers.
    """
    return re.findall(r'identifier:\s*"([A-Za-z0-9_]+)"', text)


def parse_android_scenarios(text: str) -> list[str]:
    """Identifiers in the `AndroidDemoScenario` enum, in declaration order."""
    body = re.search(r"enum class AndroidDemoScenario\b.*?\{(.*?)\n\s*;", text, re.S)
    if body is None:
        return []
    return re.findall(r'^\s*[A-Z][A-Za-z0-9_]*\("([A-Za-z0-9_]+)"\)', body.group(1), re.M)


def roster_difference(ios: list[str], android: list[str]) -> tuple[list[str], list[str]]:
    """(iOS-only, Android-only), each sorted. Empty pair means agreement."""
    return sorted(set(ios) - set(android)), sorted(set(android) - set(ios))


def parse_catalog(text: str) -> list[str]:
    """Read the canonical identifiers, ignoring comments and blank lines."""
    identifiers = [line.strip() for line in text.splitlines()
                   if line.strip() and not line.lstrip().startswith("#")]
    invalid = [name for name in identifiers if re.fullmatch(r"[A-Za-z0-9_]+", name) is None]
    if invalid:
        raise ValueError(f"invalid scenario identifier(s): {', '.join(invalid)}")
    if len(identifiers) != len(set(identifiers)):
        raise ValueError("duplicate scenario identifier in catalog")
    return identifiers


def ios_launch_command(udid: str, scenario: str) -> list[str]:
    """`simctl launch` with the scenario argument.

    A concrete UDID, never a device name: several installed simulators can
    share a name, so a name-based selection is ambiguous (AGENTS.md).
    """
    return [
        "xcrun", "simctl", "launch", udid, IOS_BUNDLE_ID,
        f"-{SCENARIO_ARG}", scenario,
    ]


def android_launch_command(scenario: str, surface: str | None = None) -> list[str]:
    command = [
        "adb", "shell", "am", "start", "-n", ANDROID_ACTIVITY,
        "--es", SCENARIO_ARG, scenario,
    ]
    if surface is not None:
        command += ["--es", SURFACE_ARG, surface]
    return command


def read(path: Path) -> str:
    if not path.is_file():
        raise SystemExit(f"scenario source is missing: {path}")
    return path.read_text(encoding="utf-8")


def load_rosters() -> tuple[list[str], list[str]]:
    return (
        parse_ios_scenarios(read(IOS_SOURCE)),
        parse_android_scenarios(read(ANDROID_SOURCE)),
    )


def load_catalog() -> list[str]:
    return parse_catalog(read(CATALOG))


def catalog_mismatches(
    catalog: list[str], ios: list[str], android: list[str]
) -> dict[str, tuple[list[str], list[str]]]:
    """Return each platform's (missing, unexpected) identifiers."""
    expected = set(catalog)
    return {
        "iOS": (sorted(expected - set(ios)), sorted(set(ios) - expected)),
        "Android": (sorted(expected - set(android)), sorted(set(android) - expected)),
    }


def command_list(_: argparse.Namespace) -> int:
    catalog = load_catalog()
    ios, android = load_rosters()
    if not catalog or not ios or not android:
        # An empty roster means the parse stopped matching, not that a
        # platform has no scenarios. Saying so beats printing an empty list
        # that reads like a fact.
        print(
            "error: the catalog or a platform roster is empty",
            file=sys.stderr,
        )
        return 1

    print(f"Catalog ({CATALOG.relative_to(ROOT)}) — {len(catalog)}")
    for name in catalog:
        print(f"  {name}")

    mismatches = catalog_mismatches(catalog, ios, android)
    failing = False
    print("\nParity")
    for platform, (missing, unexpected) in mismatches.items():
        if not missing and not unexpected:
            print(f"  {platform}: matches")
            continue
        failing = True
        print(f"  {platform}: mismatch")
        for name in missing:
            print(f"    missing:    {name}")
        for name in unexpected:
            print(f"    unexpected: {name}")

    print("\nSurfaces")
    print(f"  Android: {', '.join(ANDROID_SURFACES)}")
    print("  iOS:     none yet — the -beid-demo-surface argument is not implemented")
    return 1 if failing else 0


def command_run(args: argparse.Namespace) -> int:
    ios, android = load_rosters()
    available = ios if args.platform == "ios" else android

    if args.scenario not in available:
        # Both apps fall back to appReviewGolden for an unknown name, so
        # passing this through would launch something and look successful.
        print(
            f"error: {args.platform} has no scenario named {args.scenario!r}.\n"
            f"       available on {args.platform}: {', '.join(available) or '(none parsed)'}\n"
            f"       the app would silently fall back to appReviewGolden, so this is refused here.",
            file=sys.stderr,
        )
        return 2

    if args.surface is not None:
        allowed = IOS_SURFACES if args.platform == "ios" else ANDROID_SURFACES
        if not allowed:
            print(
                f"error: {args.platform} has no surface argument yet, so --surface cannot be honoured.\n"
                f"       refusing rather than passing an argument the app does not read.",
                file=sys.stderr,
            )
            return 2
        if args.surface not in allowed:
            print(
                f"error: unknown surface {args.surface!r}; {args.platform} accepts: {', '.join(allowed)}",
                file=sys.stderr,
            )
            return 2

    if args.platform == "ios":
        if not args.udid:
            print(
                "error: --udid is required for iOS. Several installed simulators can share a\n"
                "       name, so a name-based destination is ambiguous; pass a concrete UDID\n"
                "       from: xcrun simctl list devices available",
                file=sys.stderr,
            )
            return 2
        command = ios_launch_command(args.udid, args.scenario)
    else:
        command = android_launch_command(args.scenario, args.surface)

    print(" ".join(command))
    if args.dry_run:
        return 0
    return subprocess.call(command)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("list", help="print both platforms' scenarios and their difference")

    run = sub.add_parser("run", help="launch one scenario on a simulator or emulator")
    run.add_argument("--platform", choices=("ios", "android"), required=True)
    run.add_argument("--scenario", required=True)
    run.add_argument("--surface", default=None)
    run.add_argument("--udid", default=None, help="required for iOS; a concrete simulator UDID")
    run.add_argument("--dry-run", action="store_true", help="print the command without running it")

    args = parser.parse_args(argv)
    return command_list(args) if args.command == "list" else command_run(args)


if __name__ == "__main__":
    raise SystemExit(main())
