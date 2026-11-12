#!/usr/bin/env python3
"""Transfer only test products, preserving modes/links and checking provenance."""

import argparse
import io
import json
from pathlib import Path, PurePosixPath
import plistlib
import tarfile


def test_run(root):
    runs = list((root / "Build/Products").glob("*.xctestrun"))
    if len(runs) != 1 or not runs[0].stat().st_size:
        raise ValueError("expected exactly one nonempty .xctestrun")
    return runs[0]


def pack(derived_data, manifest_path, archive_path, provenance, checkout):
    test_run(derived_data)
    manifest = json.loads(manifest_path.read_text())
    manifest.update(provenance, source_derived_data=str(derived_data.resolve()),
                    source_checkout=str(checkout.resolve()))
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    with tarfile.open(archive_path, "w", dereference=False) as archive:
        archive.add(derived_data / "Build/Products", arcname="Build/Products")
        data = manifest_path.read_bytes()
        info = tarfile.TarInfo("manifest.json")
        info.size, info.mode = len(data), 0o644
        archive.addfile(info, io.BytesIO(data))


def unpack(archive_path, derived_data, checkout, sha, provenance):
    if derived_data.exists():
        raise ValueError("test DerivedData must be fresh")
    with tarfile.open(archive_path) as archive:
        manifests = [member for member in archive.getmembers() if member.name == "manifest.json"]
        if len(manifests) != 1 or not manifests[0].isfile():
            raise ValueError("archive has no unique manifest")
        manifest = json.load(archive.extractfile(manifests[0]))
        for key, expected in {"sha": sha, **provenance}.items():
            if manifest.get(key) != expected:
                raise ValueError(f"test product provenance mismatch: {key}")
        for member in archive.getmembers():
            path = PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts or not (
                member.name == "manifest.json" or path.is_relative_to("Build/Products")
            ) or not (member.isfile() or member.isdir() or member.issym()):
                raise ValueError(f"unsafe product archive member: {member.name}")
            if member.issym():
                target = (derived_data / path.parent / member.linkname).resolve()
                if not target.is_relative_to((derived_data / "Build/Products").resolve()):
                    raise ValueError(f"product symlink escapes archive: {member.name}")
        derived_data.mkdir(parents=True)
        archive.extractall(derived_data, filter="data")
    run = test_run(derived_data)

    def relocate(value):
        if isinstance(value, str):
            return value.replace(manifest["source_derived_data"], str(derived_data.resolve())).replace(
                manifest["source_checkout"], str(checkout.resolve()))
        if isinstance(value, list):
            return [relocate(item) for item in value]
        if isinstance(value, dict):
            return {key: relocate(item) for key, item in value.items()}
        return value

    run.write_bytes(plistlib.dumps(relocate(plistlib.loads(run.read_bytes()))))
    return run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("pack", "unpack"))
    parser.add_argument("--derived-data", type=Path, required=True)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--checkout", type=Path, default=Path.cwd())
    parser.add_argument("--sha", required=True)
    parser.add_argument("--xcode", required=True)
    parser.add_argument("--sdk", required=True)
    parser.add_argument("--arch", required=True)
    args = parser.parse_args()
    provenance = {key: getattr(args, key) for key in ("xcode", "sdk", "arch")}
    try:
        if args.command == "pack":
            if not args.manifest:
                parser.error("pack requires --manifest")
            if json.loads(args.manifest.read_text()).get("sha") != args.sha:
                raise ValueError("manifest head mismatch")
            pack(args.derived_data, args.manifest, args.archive, provenance, args.checkout)
        else:
            print(unpack(args.archive, args.derived_data, args.checkout, args.sha, provenance))
        return 0
    except (OSError, ValueError, KeyError, tarfile.TarError, plistlib.InvalidFileException) as error:
        parser.exit(1, f"iOS product handoff failed: {error}\n")


if __name__ == "__main__":
    raise SystemExit(main())
