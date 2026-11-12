#!/usr/bin/env python3
"""Retain Xcode output and UTC phase observations without hiding child failures."""

import argparse
from collections import deque
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phase", choices=("spm", "build"), required=True)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--timings", type=Path, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a child command is required")
    args.log.parent.mkdir(parents=True, exist_ok=True)
    args.timings.parent.mkdir(parents=True, exist_ok=True)
    active = {}
    with args.log.open("w", encoding="utf-8") as log, args.timings.open("a", encoding="utf-8") as timings:
        def record(phase, event, **extra):
            now = time.monotonic()
            data = {"phase": phase, "event": event,
                    "utc": datetime.now(timezone.utc).isoformat(), **extra}
            if event == "start":
                active[phase] = now
            elif phase in active:
                data["elapsed_seconds"] = now - active.pop(phase)
            timings.write(json.dumps(data) + "\n")
            timings.flush()
            print(json.dumps(data), flush=True)

        record(args.phase, "start")
        tail = deque(maxlen=60)
        with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              text=True, encoding="utf-8", errors="replace") as child:
            for line in child.stdout:
                log.write(line)
                tail.append(line)
                if args.phase != "build":
                    continue
                if line.startswith("PhaseScriptExecution ") and "BeidSharedKit" in line:
                    record("kmp", "start")
                if "kmp" in active and line.startswith(("BUILD SUCCESSFUL", "BUILD FAILED")):
                    record("kmp", "end" if line.startswith("BUILD SUCCESSFUL") else "incomplete")
                if line.startswith(("SwiftCompile ", "SwiftEmitModule ", "SwiftDriver ")):
                    if "swift-compile-window" not in active:
                        record("swift-compile-window", "start")
            code = child.wait()
        # This window includes overlapping compilation/linking. Xcode's
        # -showBuildTimingSummary in the raw log gives actual task durations.
        for phase in list(active):
            if phase != args.phase:
                record(phase, "end" if code == 0 and phase != "kmp" else "incomplete")
        record(args.phase, "end", exit_code=code)
        if code:
            print("".join(tail), end="")
        print(f"Raw build log: {args.log}")
        return code


if __name__ == "__main__":
    raise SystemExit(main())
