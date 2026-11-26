"""Copy the complete Kotlin Swift Export product between clean simulator builds."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile


TRIPLE = "arm64-apple-ios-simulator"
MODULES = ("BeidSharedKit", "ExportedKotlinPackages", "KotlinStdlib", "KotlinRuntimeSupport")
FILES = {"libBeidSharedKit.a"}
for module in MODULES:
    for member in (f"{TRIPLE}.swiftmodule", f"{TRIPLE}.swiftdoc", f"{TRIPLE}.abi.json",
                   f"Project/{TRIPLE}.swiftsourceinfo"):
        FILES.add(f"{module}.swiftmodule/{member}")
for module, header in (("KotlinRuntime", "KotlinBase.h"), ("SharedBridge_BeidSharedKit", "BeidSharedKit.h"),
                       ("KotlinBridges_KotlinStdlib", "KotlinStdlib.h")):
    FILES.update((f"{module}/{header}", f"{module}/module.modulemap"))
ROOTS = sorted({name.split("/")[0] for name in FILES})


def hashes(products):
    seen = {}
    for root in ROOTS:
        base = products / root
        for item in [base, *base.rglob("*")]:
            if item.is_symlink():
                raise ValueError("unexpected symlink in export")
            if item.is_dir():
                continue
            if not item.is_file() or not item.stat().st_size:
                raise ValueError(f"missing or empty export file: {item.name}")
            relative = item.relative_to(products).as_posix()
            if relative not in FILES:
                raise ValueError(f"unexpected export member: {relative}")
            seen[relative] = {"sha256": hashlib.sha256(item.read_bytes()).hexdigest(),
                              "mode": stat.S_IMODE(item.stat().st_mode), "size": item.stat().st_size}
    if set(seen) != FILES:
        raise ValueError("incomplete export")
    return seen


def copy_files(source, destination):
    for name in sorted(FILES):
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / name, target)


def snapshot(source, entry, key, producer=None):
    if not re.fullmatch("[0-9a-f]{64}", key):
        raise ValueError("invalid export key")
    digests = hashes(source)
    entry.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=entry.parent) as temp:
        staged = Path(temp) / "entry"
        copy_files(source, staged / "products")
        if hashes(staged / "products") != digests:
            raise ValueError("export changed while copying")
        (staged / "manifest.json").write_text(json.dumps({"key": key, "files": digests, "producer": producer}, sort_keys=True))
        staged.rename(entry)


def verify(entry, key):
    if not re.fullmatch("[0-9a-f]{64}", key):
        raise ValueError("invalid export key")
    if entry.is_symlink() or (entry / "manifest.json").is_symlink() or (entry / "products").is_symlink():
        raise ValueError("linked cache entry")
    manifest = json.loads((entry / "manifest.json").read_text())
    if manifest.get("key") != key:
        raise ValueError("different export key")
    source = entry / "products"
    if {p.name for p in entry.iterdir()} != {"manifest.json", "products"} or {p.name for p in source.iterdir()} != set(ROOTS):
        raise ValueError("unexpected cache contents")
    if hashes(source) != manifest.get("files"):
        raise ValueError("export file hashes differ")
    return source


def install(entry, destination, key):
    if destination.name != "Debug-iphonesimulator":
        raise ValueError("unexpected destination")
    source = verify(entry, key)
    if destination.is_symlink() or any(os.path.lexists(destination / root) for root in ROOTS):
        raise ValueError("Swift Export outputs already exist")
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination) as temp:
        staged = Path(temp)
        copy_files(source, staged)
        installed = []
        try:
            for name in ROOTS:
                (staged / name).rename(destination / name)
                installed.append(name)
        except OSError:
            for name in reversed(installed):
                (destination / name).rename(staged / name)
            raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("snapshot", "install", "verify"))
    parser.add_argument("--products", type=Path)
    parser.add_argument("--entry", required=True, type=Path)
    parser.add_argument("--key", required=True)
    args = parser.parse_args()
    # Only the CI CLI accepts a real, arm64-only static archive.
    products = args.products if args.operation == "snapshot" else args.entry / "products"
    if products is not None:
        library = products / "libBeidSharedKit.a"
        if library.is_symlink() or subprocess.check_output(["xcrun", "lipo", "-archs", str(library)]).split() != [b"arm64"]:
            parser.error("expected an arm64 static library")
    if args.operation == "verify":
        verify(args.entry, args.key)
    elif args.products is None:
        parser.error("--products is required for snapshot and install")
    elif args.operation == "snapshot":
        snapshot(args.products, args.entry, args.key, {"sha": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
                                                     "run": os.environ.get("GITHUB_RUN_ID"),
                                                     "attempt": os.environ.get("GITHUB_RUN_ATTEMPT")})
    else:
        install(args.entry, args.products, args.key)
