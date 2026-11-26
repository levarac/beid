"""Content key for the hosted arm64 iPhone Simulator Kotlin Release export."""
import argparse
from functools import lru_cache
import hashlib
import json
import os
from pathlib import Path
import subprocess


def command(*args):
    return subprocess.check_output(args).strip()


def tracked_input(name):
    path = Path(name)
    return ((name.startswith("android/") and not name.startswith("android/app/src/"))
            or name.startswith(("shared/", ".github/actions/ios-swift-export/",
                             "scripts/ios_swift_export"))
            or path.name in {"gradle.properties", "gradle.lockfile", "gradlew", "gradlew.bat"}
            or name.endswith((".gradle", ".gradle.kts", ".lockfile"))
            or any(p in {"buildSrc", "build-logic"} for p in path.parts)
            or name in {"android/version.properties", "ios/project.yml", "ios/Version.xcconfig",
                        "ios/Beid.xcodeproj/project.pbxproj", "ios/ci_scripts/XCODEGEN_VERSION",
                        ".github/workflows/pr-ci-ios-macos.yml", ".github/workflows/ios-swift-export-seed.yml",
                        "scripts/download_xcodegen.sh", "scripts/resolve_kmp_java_home.sh",
                        "scripts/xcodegen_generate_checked.sh"})


def add_record(digest, *fields):
    for field in fields:
        data = os.fsencode(field)
        digest.update(len(data).to_bytes(8, "big"))
        digest.update(data)


@lru_cache(maxsize=None)
def content(path):
    digest = hashlib.sha256()
    if path.is_dir():
        for item in sorted(path.iterdir()):
            add_record(digest, item.name, content(item))
    else:
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
    return digest.hexdigest()


def cache_key(repo, resolved, dependencies, toolchain):
    digest = hashlib.sha256()
    files = command("git", "-C", str(repo), "ls-files", "-z").split(b"\0")
    for name in sorted(os.fsdecode(n) for n in files if n):
        if tracked_input(name):
            path = repo / name
            if path.is_symlink():
                raise ValueError("linked build input")
            add_record(digest, name, str(bool(path.stat().st_mode & 0o111)), content(path))
    rows = json.loads(resolved.read_text())
    if not rows:
        raise ValueError("missing Gradle inputs")
    for configuration, coordinate, filename, path in sorted(rows):
        add_record(digest, configuration, coordinate, filename, content(Path(path)))
    # Kotlin/Native downloads its host LLVM and libffi outside Gradle resolution.
    tools = sorted(p for p in dependencies.iterdir() if p.is_dir() and p.name != "cache")
    if not any(p.name.startswith("llvm-") for p in tools) or not any(p.name.startswith("libffi-") for p in tools):
        raise ValueError("native host tools have not been provisioned")
    for path in tools:
        add_record(digest, path.name, content(path))
    for value in toolchain:
        if not value:
            raise ValueError("incomplete toolchain fingerprint")
        add_record(digest, value)
    return digest.hexdigest()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("resolved", type=Path)
    args = parser.parse_args()
    java = Path(os.environ["JAVA_HOME"], "bin/java")
    version = subprocess.check_output([str(java), "-version"], stderr=subprocess.STDOUT)
    print(cache_key(Path.cwd(), args.resolved, Path.home() / ".konan/dependencies", [
        os.environ["ImageOS"], os.environ["ImageVersion"], command("sw_vers", "-buildVersion"),
        command("uname", "-m"), command("xcodebuild", "-version"), command("xcrun", "swiftc", "--version"),
        command("xcrun", "clang", "--version"), command("xcrun", "--sdk", "iphonesimulator", "--show-sdk-build-version"),
        version, "arm64-apple-ios-simulator/Debug/Release/-O/17.0",
    ]))
