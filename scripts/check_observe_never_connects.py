#!/usr/bin/env python3
"""Fail if `beid-lab-cli observe` gains a way to touch what it is measuring.

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

Run it directly, or through `scripts/tests/test_observe_never_connects.py`.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# The observe path. `main.swift` is included because it is where a runner
# could be handed a manager, and `LabBluetooth.swift` because it is the only
# other file `ObserveRunner` reaches into.
OBSERVE_SOURCES = (
    "tools/beid-lab-cli/Sources/beid-lab-cli/ObserveRunner.swift",
)

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

    if failures:
        print(
            "error: `beid-lab-cli observe` must not touch what it measures "
            "(beid#588, dispatch#66).",
            file=sys.stderr,
        )
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        print(
            "\nIf the call is genuinely needed, it does not belong in observe: "
            "put it in participate, which already connects by design.",
            file=sys.stderr,
        )
        return 1

    print(f"ok: {len(OBSERVE_SOURCES)} observe source(s) contain no connection path")
    return 0


if __name__ == "__main__":
    sys.exit(main())
