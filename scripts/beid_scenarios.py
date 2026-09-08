#!/usr/bin/env python3
"""List beid's demo scenarios and launch one on a simulator or emulator.

beid#399: a developer should not have to remember the shape of
`-beid-demo-scenario` or `am start --es beid-demo-scenario` to see a scenario
running.

**Why this reads both platforms instead of nominating one as authoritative.**
The scenario identifiers exist twice — `DemoScenario.allScenarios` in Swift and
the `AndroidDemoScenario` enum in Kotlin — and the two are not required to
agree at any given commit. Reading one and reporting it as "the scenarios"
would print a roster that is true of neither platform whenever they diverge,
and a divergence is a real product fact rather than noise.

No counts are quoted here on purpose. Whether the two rosters currently agree
is exactly what this command exists to answer, and a number written into this
docstring would be a second, unmaintained copy of that answer — stale the next
time either roster moves, which sibling work does routinely.

So this prints two rosters, names the platform on each, and prints the
difference explicitly. It does not reconcile them and does not pick a winner.
If they converge later, the difference section simply goes empty — which is
the correct behaviour rather than a special case to remove.

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


def command_list(_: argparse.Namespace) -> int:
    ios, android = load_rosters()
    if not ios or not android:
        # An empty roster means the parse stopped matching, not that a
        # platform has no scenarios. Saying so beats printing an empty list
        # that reads like a fact.
        print(
            "warning: a scenario roster came back empty, which usually means the "
            "source layout changed and the parse no longer matches",
            file=sys.stderr,
        )

    print(f"iOS ({IOS_SOURCE.relative_to(ROOT)}) — {len(ios)}")
    for name in ios:
        print(f"  {name}")
    print(f"\nAndroid ({ANDROID_SOURCE.relative_to(ROOT)}) — {len(android)}")
    for name in android:
        print(f"  {name}")

    ios_only, android_only = roster_difference(ios, android)
    print("\nDifference")
    if not ios_only and not android_only:
        print("  none — both platforms carry the same scenario names")
    for name in ios_only:
        print(f"  iOS only:     {name}")
    for name in android_only:
        print(f"  Android only: {name}")

    print("\nSurfaces")
    print(f"  Android: {', '.join(ANDROID_SURFACES)}")
    print("  iOS:     none yet — the -beid-demo-surface argument is not implemented")
    return 0


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
