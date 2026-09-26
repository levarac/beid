#!/usr/bin/env python3
"""Create a fresh CI iPhone and print only its UDID for the caller to own.

Never enumerate or reuse existing devices. The caller must delete the returned
UDID in its cleanup step, including when boot, build, or tests fail.
"""

import argparse
import json
import subprocess
import sys
import uuid


def create_simulator(name: str, runtime_name: str) -> str:
    result = subprocess.run(
        ["xcrun", "simctl", "list", "runtimes", "--json"],
        check=True, capture_output=True, text=True,
    )
    runtime = next(
        (item for item in json.loads(result.stdout)["runtimes"]
         if item.get("isAvailable") is True and item.get("name") == runtime_name),
        None,
    )
    if runtime is None:
        raise ValueError(f"no available {runtime_name} runtime")
    iphones = sorted(
        item["identifier"] for item in runtime.get("supportedDeviceTypes", [])
        if item.get("identifier", "").startswith("com.apple.CoreSimulator.SimDeviceType.iPhone-")
    )
    if not iphones:
        raise ValueError(f"no supported iPhone device type for {runtime_name}")

    result = subprocess.run(
        ["xcrun", "simctl", "create", f"{name}-{uuid.uuid4()}",
         iphones[0], runtime["identifier"]],
        check=True, capture_output=True, text=True,
    )
    udid = result.stdout.strip()
    try:
        if str(uuid.UUID(udid)).upper() != udid.upper():
            raise ValueError("noncanonical UUID")
    except ValueError as error:
        raise ValueError("simctl create returned an invalid simulator UDID") from error
    return udid


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", required=True, help="CI run/job name prefix")
    parser.add_argument("--runtime", default="iOS 26.5")
    args = parser.parse_args()
    try:
        print(create_simulator(args.name, args.runtime))
    except (ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
