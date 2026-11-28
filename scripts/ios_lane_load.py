"""Collect optional macOS UI shard observations in the lane's isolated output root."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time


INTERVAL = 5
MAX_BYTES = 256 * 1024
MAX_SAMPLES = 660  # 55-minute job at five seconds per sample
VM_FIELDS = {"Pageouts": "pageouts", "Swapouts": "swapouts", "Pages occupied by compressor": "compressor_pages"}
METRICS = {"utc_ms", "monotonic_s", "io_elapsed_s", "cpu_user_pct", "cpu_system_pct", "cpu_idle_pct",
           "pressure_level", "disk_free_bytes", *VM_FIELDS.values()}


def probe(*args, timeout=2):
    try:
        return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL, timeout=timeout,
                                       env={"LC_ALL": "C"})
    except (OSError, subprocess.SubprocessError):
        return ""


def interval_io(output):
    # Darwin iostat -dC prints devices, units, a since-boot row and the interval row.
    lines = [line.split() for line in output.splitlines() if line.strip()]
    if len(lines) != 4:
        return {}
    devices, units, _, values = lines
    disks = devices[:-1]
    if (devices[-1:] != ["cpu"] or units != ["KB/t", "tps", "MB/s"] * len(disks) + ["us", "sy", "id"]
            or len(values) != len(units)):
        return {}
    try:
        row = dict(zip(("cpu_user_pct", "cpu_system_pct", "cpu_idle_pct"), map(int, values[-3:])))
        for i, disk in enumerate(disks):
            if re.fullmatch(r"disk[0-9]{1,3}", disk):
                row[disk + "_tps"] = int(values[i * 3 + 1])
                row[disk + "_MB_s"] = float(values[i * 3 + 2])
        return row
    except ValueError:
        return {}


def sample(root):
    before = time.monotonic()
    row = interval_io(probe("/usr/sbin/iostat", "-dC", "-n", "4", "-c", "2", "-w", str(INTERVAL),
                            timeout=INTERVAL + 2))
    now = time.monotonic()
    row.update(utc_ms=time.time_ns() // 1_000_000,
               monotonic_s=round(now, 3), io_elapsed_s=round(now - before, 3))
    pressure = probe("/usr/sbin/sysctl", "-n", "kern.memorystatus_vm_pressure_level").strip()
    if pressure.isdecimal():
        row["pressure_level"] = int(pressure)
    # Keep cumulative page counts so missing samples still allow deltas between valid readings.
    for label, number in re.findall(r"^([^:\n]+):\s*(\d+)\.$", probe("/usr/bin/vm_stat"), re.MULTILINE):
        if label in VM_FIELDS:
            row[VM_FIELDS[label]] = int(number)
    try:
        row["disk_free_bytes"] = shutil.disk_usage(root).free
    except OSError:
        pass
    return row


def collect(root):
    stop = root / "ui-load.stop"
    with (root / "ui-load.live").open("xb") as output:
        for _ in range(MAX_SAMPLES):
            if stop.exists():
                break
            started = time.monotonic()
            line = (json.dumps(sample(root), separators=(",", ":")) + "\n").encode()
            if stop.exists() or output.tell() + len(line) > MAX_BYTES:
                break
            output.write(line)
            output.flush()
            # A missing iostat must not turn the collector into a busy loop.
            time.sleep(max(0, INTERVAL - (time.monotonic() - started)))


def finish(root):
    try:
        (root / "ui-load.stop").touch()
    except OSError:
        pass  # A full disk can still have readable samples.
    live = root / "ui-load.live"
    data = b""
    if not live.is_symlink() and live.is_file():
        with live.open("rb") as source:
            data = source.read(MAX_BYTES)
    header = {"schema": 1, "page_bytes": os.sysconf("SC_PAGE_SIZE"),
              "logical_cpus": os.sysconf("SC_NPROCESSORS_ONLN")}
    print("BEID_UI_LOAD", json.dumps(header, separators=(",", ":")))
    remaining = MAX_BYTES - 256  # Reserve space for the header and footer.
    rows = 0
    # A concurrent final write may be incomplete. Never echo unvalidated text into the public job log.
    for line in data[:data.rfind(b"\n") + 1].splitlines():
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if not isinstance(record, dict):
            continue
        public = {k: v for k, v in record.items()
                  if (k in METRICS or re.fullmatch(r"disk[0-9]{1,3}_(tps|MB_s)", k))
                  and type(v) in (int, float) and 0 <= v <= 2**63 - 1}
        if "utc_ms" not in public:
            continue
        text = "BEID_UI_LOAD " + json.dumps(public, separators=(",", ":"))
        if rows == MAX_SAMPLES or len(text) + 1 > remaining:
            break
        print(text)
        remaining -= len(text) + 1
        rows += 1
    print("BEID_UI_LOAD", json.dumps({"samples": rows}, separators=(",", ":")))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("collect", "finish"))
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    if args.command == "collect":
        collect(args.root)
    else:
        finish(args.root)
