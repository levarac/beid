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


# Deliberate fallbacks for the pinned CI runtime, newest first. Do not silently
# select an arbitrary model when runner images change their supported devices.
PREFERRED_DEVICE_TYPES = (
    "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro",
    "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
    "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro",
)


def command_failure(error: subprocess.CalledProcessError) -> str:
    return f"{error}: {error.stderr.strip()}" if error.stderr else str(error)


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
    supported = {item.get("identifier") for item in runtime.get("supportedDeviceTypes", [])}
    device_type = next((item for item in PREFERRED_DEVICE_TYPES if item in supported), None)
    if device_type is None:
        raise ValueError(f"no preferred iPhone device type supported by {runtime_name}")

    device_name = f"{name}-{uuid.uuid4()}"
    result = subprocess.run(
        ["xcrun", "simctl", "create", device_name, device_type, runtime["identifier"]],
        check=True, capture_output=True, text=True,
    )
    udid = result.stdout.strip()
    try:
        if str(uuid.UUID(udid)).upper() != udid.upper():
            raise ValueError("noncanonical UUID")
    except ValueError as error:
        # Creation succeeded, but the caller cannot safely own this output.
        # Delete our unique name, never an unvalidated alias such as "all" or
        # "booted", and preserve cleanup failures alongside the original error.
        try:
            subprocess.run(
                ["xcrun", "simctl", "delete", device_name],
                check=True, capture_output=True, text=True,
            )
        except subprocess.CalledProcessError as cleanup_error:
            raise ValueError(
                "simctl create returned an invalid simulator UDID; "
                f"cleanup failed: {command_failure(cleanup_error)}"
            ) from error
        raise ValueError("simctl create returned an invalid simulator UDID") from error
    return udid


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", required=True, help="CI run/job name prefix")
    parser.add_argument("--runtime", default="iOS 26.5")
    args = parser.parse_args()
    try:
        print(create_simulator(args.name, args.runtime))
    except subprocess.CalledProcessError as error:
        print(f"error: {command_failure(error)}", file=sys.stderr)
        return 1
    except (ValueError, KeyError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
