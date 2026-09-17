#!/usr/bin/env python3
"""Fail if `beid-lab-cli observe` stops being a passive, correctly-aimed instrument.

Two properties, both invisible in a diff and both silent when broken.

`observe` exists to answer dispatch#66 -- did a venue really stop emitting --
and an instrument that connects to the thing it measures is not measuring it.
`BarnardEngine`'s own scan is not passive: every discovery that clears its
RSSI guard is enqueued for a connect, and a connect leads to GATT reads. That
is precisely why `ObserveRunner` is a bare `CBCentralManager` rather than the
engine.

The property this guards is invisible in a diff. A `connect` added to
`ObserveRunner` would look like an ordinary feature -- read the peer's name,
confirm a service is really there -- and would silently perturb every
measurement taken afterwards, including ones whose numbers are already in a
report. Nothing in a code review reliably catches "this used to be passive".

So this is a text scan over the observe sources, not a proof about runtime
behaviour. It cannot see through a selector built at runtime or a call made
from another file on a manager this one handed out. It catches the plausible
regression -- somebody adds the obvious call -- which is the one that will
actually happen.

**Second: the scan must name Barnard's discovery service.** chk-beid-590
mutated `withServices: [B001]` to `withServices: nil` on PR #590 and the whole
Swift suite stayed green, as did this checker's first property. An iOS app
advertising in the background moves its service UUID into the advertisement's
overflow area, which CoreBluetooth surfaces only to a scan that names that
UUID -- so a `nil` filter misses exactly the backgrounded phones the
instrument is pointed at, and the run reports "nobody was in the room". That
is the same failure class as the first property, reached from the other end.

A Swift test cannot see a CoreBluetooth call argument, which is why the check
lives here. The UUID itself is pinned by `LabScanPolicyTests`; this asserts
that `ObserveRunner` actually uses it.

Run it directly, or through `scripts/tests/test_observe_never_connects.py`.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# The observe path.
#
# `LabBluetooth.swift` is here because `ObserveRunner` reaches into it and
# nothing in a Bluetooth-availability helper has any business opening a
# connection.
#
# `main.swift` is deliberately NOT here, and the difference is worth stating
# because an earlier version of this comment claimed it was (chk-beid-590,
# G3). It constructs all three runners, so forbidding `BarnardEngine(` there
# would block `venue` and `participate`, which connect by design. Its
# `ObserveRunner` construction passes no manager, and if that ever changes the
# reviewer of that change is the control, not this script.
OBSERVE_SOURCES = (
    "tools/beid-lab-cli/Sources/beid-lab-cli/ObserveRunner.swift",
    "tools/beid-lab-cli/Sources/beid-lab-cli/LabBluetooth.swift",
)

# The file that must aim the scan, and the file that defines what at.
SCAN_SOURCE = "tools/beid-lab-cli/Sources/beid-lab-cli/ObserveRunner.swift"
SCAN_POLICY_SOURCE = "tools/beid-lab-cli/Sources/BeidLabCliCore/LabScanPolicy.swift"

# `withServices:` must be handed the policy's UUID, never nil. Matching the
# literal `nil` separately from "did it reference the policy" lets the failure
# message say which mistake was made.
SCAN_CALL = re.compile(r"scanForPeripherals\s*\(", re.MULTILINE)
SCAN_SERVICES_NIL = re.compile(r"withServices:\s*nil")
SCAN_POLICY_UUID = re.compile(
    r'discoveryServiceUUIDString\s*=\s*"([0-9A-Fa-f-]{36})"')

# CoreBluetooth central-side calls that reach out and touch a peripheral, and
# the peripheral-side calls that would make this process appear on the air at
# all. Spelled with the trailing `(` so the words can still be used in prose.
FORBIDDEN = {
    "connect(": "connects to a peripheral",
    "cancelPeripheralConnection(": "implies a connection was opened",
    "discoverServices(": "requires an open connection",
    "discoverCharacteristics(": "requires an open connection",
    "readValue(": "reads a characteristic over a connection",
    "writeValue(": "writes a characteristic over a connection",
    "setNotifyValue(": "subscribes over a connection",
    "retrieveConnectedPeripherals(": "reaches for existing connections",
    "retrievePeripherals(": "reaches for peripherals by identifier",
    "readRSSI(": "requires an open connection",
    "CBPeripheralManager(": "would put this process on the air",
    "startAdvertising(": "would put this process on the air",
    "BarnardEngine(": "the engine's scan enqueues connects",
}

# `//` and `///` comments describe the rule and name the calls, so they are
# stripped before matching. A string literal is not stripped: a selector
# hidden in one is exactly the case worth flagging for a human to look at.
COMMENT = re.compile(r"//.*$")


def offending_lines(text: str) -> list[tuple[int, str, str]]:
    found = []
    for number, raw in enumerate(text.splitlines(), start=1):
        line = COMMENT.sub("", raw)
        for needle, why in FORBIDDEN.items():
            if needle in line:
                found.append((number, needle, why))
    return found


def scan_failures(root: Path) -> list[str]:
    """Check that observe's scan names the discovery service."""
    failures = []
    policy_path = root / SCAN_POLICY_SOURCE
    scan_path = root / SCAN_SOURCE
    if not policy_path.exists():
        return [f"{SCAN_POLICY_SOURCE}: not found; where did the scan policy go?"]
    if not scan_path.exists():
        return [f"{SCAN_SOURCE}: not found; did the observe path move?"]

    policy_text = policy_path.read_text(encoding="utf-8")
    match = SCAN_POLICY_UUID.search(policy_text)
    if not match:
        failures.append(
            f"{SCAN_POLICY_SOURCE}: no `discoveryServiceUUIDString = \"<uuid>\"` found"
        )

    scan_text = scan_path.read_text(encoding="utf-8")
    body = "\n".join(COMMENT.sub("", line) for line in scan_text.splitlines())

    if not SCAN_CALL.search(body):
        failures.append(f"{SCAN_SOURCE}: no `scanForPeripherals(` call -- does observe still scan?")
    if SCAN_SERVICES_NIL.search(body):
        failures.append(
            f"{SCAN_SOURCE}: `withServices: nil` scans for everything and therefore misses "
            "backgrounded iOS advertisers, whose service UUID sits in the advertisement's "
            "overflow area and reaches only a scan that names it"
        )
    if "LabScanPolicy.discoveryServiceUUIDString" not in body:
        failures.append(
            f"{SCAN_SOURCE}: the scan must take its service UUID from "
            "`LabScanPolicy.discoveryServiceUUIDString`, so the value a test pins and the "
            "value the radio receives cannot drift apart"
        )
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root", default=str(REPO_ROOT), help="repository root (default: this checkout)"
    )
    args = parser.parse_args()
    root = Path(args.root)

    failures = []
    for relative in OBSERVE_SOURCES:
        path = root / relative
        if not path.exists():
            # A missing file is a failure, not a pass. Silently checking
            # nothing is how a guard like this stops working after a rename.
            failures.append(f"{relative}: not found; did the observe path move?")
            continue
        for number, needle, why in offending_lines(path.read_text(encoding="utf-8")):
            failures.append(f"{relative}:{number}: `{needle}` -- {why}")

    failures.extend(scan_failures(root))

    if failures:
        print(
            "error: `beid-lab-cli observe` must stay passive and correctly aimed "
            "(beid#588, dispatch#66).",
            file=sys.stderr,
        )
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        print(
            "\nIf a connection is genuinely needed, it does not belong in observe: "
            "put it in participate, which already connects by design.",
            file=sys.stderr,
        )
        return 1

    print(
        f"ok: {len(OBSERVE_SOURCES)} observe source(s) contain no connection path, "
        "and the scan names the discovery service"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
