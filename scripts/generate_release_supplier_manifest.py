#!/usr/bin/env python3
"""Generate Parallax's public Beid build/Barnard supplier fragment.

Inputs are immutable evidence exports, not live release-system responses.  The
tool needs no credentials and publishes one explicit output file.  Synthetic evidence is rejected unless the caller opts
in; that switch exists solely for the checked-in fixtures.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from tempfile import TemporaryDirectory
from pathlib import Path

from check_barnard_dependency_provenance import declared_version
from check_lab_cli_barnard_pin import project_pin

ROOT = Path(__file__).resolve().parent.parent
IOS_PROJECT = Path("ios/project.yml")
ANDROID_BUILD = Path("android/app/build.gradle.kts")
IOS_RESOLVED = Path("ios/Beid.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
COMMIT_RE = re.compile(r"[0-9a-f]{40}")
SHA256_RE = re.compile(r"[0-9a-f]{64}")


def fail(message: str) -> None:
    raise ValueError(message)


def text(obj: dict, key: str) -> str:
    value = obj.get(key)
    if not isinstance(value, str) or not value.strip() or value.strip().upper() == "TBD":
        fail(f"missing or invalid {key}")
    return value


def integer(obj: dict, key: str) -> int:
    value = obj.get(key)
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        fail(f"missing or invalid {key}")
    return value


def ios_source_pin(root: Path) -> tuple[str, str]:
    document = json.loads((root / IOS_RESOLVED).read_text(encoding="utf-8"))
    pins = [p for p in document.get("pins", []) if p.get("identity") == "barnard"]
    if len(pins) != 1:
        fail(f"{IOS_RESOLVED} must contain exactly one barnard pin")
    state = pins[0].get("state", {})
    return text(state, "version"), text(state, "revision")


def load(path: Path, expected_format: str, allow_synthetic: bool) -> dict:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict) or value.get("format") != expected_format:
        fail(f"{path}: format must be exactly {expected_format!r}")
    if "synthetic" in value and not isinstance(value["synthetic"], bool):
        fail(f"{path}: synthetic must be a boolean")
    if value.get("synthetic") is True and not allow_synthetic:
        fail(f"{path}: synthetic evidence requires --allow-synthetic")
    receipt = value.get("receipt")
    if not isinstance(receipt, dict):
        fail(f"{path}: missing receipt")
    if receipt.get("kind") not in {"public-url", "offline-package"}:
        fail(f"{path}: receipt.kind must be public-url or offline-package")
    if not SHA256_RE.fullmatch(text(receipt, "sha256")):
        fail(f"{path}: receipt.sha256 must be 64 lowercase hex characters")
    locator = text(receipt, "locator")
    if receipt["kind"] == "public-url" and not locator.startswith("https://"):
        fail(f"{path}: a public-url receipt must use https")
    return value


def barnard_identity(evidence: dict, platform: str) -> tuple[str, str]:
    identity = evidence.get("barnard")
    if not isinstance(identity, dict):
        fail(f"{platform}: missing packaged Barnard identity")
    tag, commit = text(identity, "tag"), text(identity, "commit")
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
        fail(f"{platform}: Barnard tag must have vX.Y.Z form")
    if not COMMIT_RE.fullmatch(commit):
        fail(f"{platform}: Barnard commit must be 40 lowercase hex characters")
    return tag, commit


def provenance(evidence: dict, candidate: str, platform: str) -> None:
    packaged = evidence.get("provenance")
    if not isinstance(packaged, dict) or text(packaged, "sourceCommit") != candidate:
        fail(f"{platform}: packaged provenance is missing or does not name candidate SHA {candidate}")


def pinned_source_identities(root: Path, candidate: str) -> tuple[str, str, str, str]:
    candidate_type = subprocess.run(
        ["git", "-C", str(root), "cat-file", "-t", candidate],
        capture_output=True,
    )
    if candidate_type.returncode or candidate_type.stdout.strip() != b"commit":
        fail("candidate SHA does not name a commit in the source repository")
    with TemporaryDirectory(prefix="beid-release-pins-") as directory:
        snapshot = Path(directory)
        for relative in (IOS_PROJECT, IOS_RESOLVED, ANDROID_BUILD):
            result = subprocess.run(
                ["git", "-C", str(root), "cat-file", "blob", f"{candidate}:{relative.as_posix()}"],
                capture_output=True,
            )
            if result.returncode:
                fail(f"candidate SHA {candidate} does not provide {relative.as_posix()}")
            target = snapshot / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(result.stdout)
        resolved_version, resolved_revision = ios_source_pin(snapshot)
        declared_ios = project_pin(snapshot)
        declared_android = declared_version(snapshot / ANDROID_BUILD)
        return declared_ios, resolved_version, resolved_revision, declared_android


def generate(root: Path, ios_path: Path, android_path: Path, candidate: str,
             allow_synthetic: bool) -> dict:
    if not COMMIT_RE.fullmatch(candidate):
        fail("candidate SHA must be 40 lowercase hex characters")
    ios = load(ios_path, "beid-ios-approved-metadata-v1", allow_synthetic)
    android = load(android_path, "beid-android-package-inspection-v1", allow_synthetic)
    provenance(ios, candidate, "ios")
    provenance(android, candidate, "android")

    declared_ios, resolved_ios, resolved_commit, declared_android = pinned_source_identities(root, candidate)
    if declared_ios != resolved_ios:
        fail(f"iOS source exactVersion {declared_ios} disagrees with Package.resolved {resolved_ios}")
    ios_tag, ios_commit = barnard_identity(ios, "ios")
    if (ios_tag, ios_commit) != (f"v{declared_ios}", resolved_commit):
        fail("iOS packaged Barnard identity disagrees with exactVersion/Package.resolved")

    proof = android.get("dependencyProof")
    if not isinstance(proof, dict):
        fail("android: missing authenticated build-time dependency proof")
    if proof.get("kind") not in {"gradle-lock", "dependency-insight"}:
        fail("android: dependencyProof.kind must be gradle-lock or dependency-insight")
    if text(proof, "coordinate") != f"org.levarac:barnard:{declared_android}":
        fail("android: dependency proof disagrees with the Gradle declaration")
    android_tag, android_commit = barnard_identity(android, "android")
    if android_tag != f"v{declared_android}":
        fail("android: packaged Barnard identity disagrees with the Gradle declaration")
    if (ios_tag, ios_commit) != (android_tag, android_commit):
        fail("platform packaged Barnard identities disagree; common identity withheld")

    ios_build = ios.get("build")
    android_build = android.get("build")
    if not isinstance(ios_build, dict) or not isinstance(android_build, dict):
        fail("missing packaged build identity")
    ios_version = text(ios_build, "version")
    ios_number = text(ios_build, "build")
    android_version = text(android_build, "versionName")
    android_code = integer(android_build, "versionCode")
    return {
        "builds": {
            "ios": f"{ios_version} ({ios_number})",
            "android": f"{android_version} ({android_code})",
        },
        "barnard": {"tag": ios_tag, "commit": ios_commit},
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ios-evidence", required=True, type=Path)
    parser.add_argument("--android-evidence", required=True, type=Path)
    parser.add_argument("--candidate-sha", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--allow-synthetic", action="store_true")
    args = parser.parse_args()
    try:
        result = generate(args.root, args.ios_evidence, args.android_evidence,
                          args.candidate_sha, args.allow_synthetic)
        encoded = json.dumps(result, indent=2) + "\n"
        with TemporaryDirectory(prefix=".beid-supplier-", dir=args.output.parent) as directory:
            staged = Path(directory) / "manifest.json"
            staged.write_text(encoded, encoding="utf-8")
            args.output.hardlink_to(staged)
        print(f"OK: 2 builds, 2 agreeing Barnard identities; candidate SHA {args.candidate_sha}")
        return 0
    except (OSError, json.JSONDecodeError, ValueError, SystemExit) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
