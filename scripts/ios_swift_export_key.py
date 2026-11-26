"""Content key for the hosted arm64 iPhone Simulator Kotlin Release export."""
import argparse
from functools import lru_cache
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


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


def cache_key(repo, resolved, dependencies, toolchain, *, component_digests=None):
    tracked = hashlib.sha256()
    files = command("git", "-C", str(repo), "ls-files", "-z").split(b"\0")
    for name in sorted(os.fsdecode(n) for n in files if n):
        if tracked_input(name):
            path = repo / name
            if path.is_symlink():
                raise ValueError("linked build input")
            add_record(tracked, name, str(bool(path.stat().st_mode & 0o111)), content(path))
    rows = json.loads(resolved.read_text())
    if not rows:
        raise ValueError("missing Gradle inputs")
    gradle = hashlib.sha256()
    for configuration, coordinate, filename, path in sorted(rows):
        add_record(gradle, configuration, coordinate, filename, content(Path(path)))
    # Kotlin/Native downloads its host LLVM and libffi outside Gradle resolution.
    tools = sorted(p for p in dependencies.iterdir() if p.is_dir() and p.name != "cache")
    if not any(p.name.startswith("llvm-") for p in tools) or not any(p.name.startswith("libffi-") for p in tools):
        raise ValueError("native host tools have not been provisioned")
    native = hashlib.sha256()
    for path in tools:
        add_record(native, path.name, content(path))
    host = hashlib.sha256()
    for value in toolchain:
        if not value:
            raise ValueError("incomplete toolchain fingerprint")
        add_record(host, value)

    components = {
        "tracked": tracked.hexdigest(),
        "gradle": gradle.hexdigest(),
        "native": native.hexdigest(),
        "host": host.hexdigest(),
    }
    if component_digests is not None:
        component_digests.update(components)
    digest = hashlib.sha256()
    for name, value in components.items():
        add_record(digest, name, value)
    return digest.hexdigest()


def host_toolchain(java_home):
    simulator = ("xcrun", "--sdk", "iphonesimulator")
    sdk = Path(os.fsdecode(command(*simulator, "--show-sdk-path")))
    java = java_home / "bin/java"
    java_version = subprocess.check_output([str(java), "-version"], stderr=subprocess.STDOUT)
    clang_version = b"\n".join(
        line for line in command(*simulator, "clang", "--version").splitlines()
        if not line.startswith(b"InstalledDir:")
    )
    # The image rollout version may change while the selected toolchain stays
    # identical. Key the platform and active tools, and log the rollout separately.
    inputs = [
        os.environ["ImageOS"], command("sw_vers", "-buildVersion"), command("uname", "-m"),
        command("xcodebuild", "-version"), command(*simulator, "swiftc", "--version"),
        clang_version, command(*simulator, "--show-sdk-build-version"),
        content(sdk / "SDKSettings.json"), java_version,
        "arm64-apple-ios-simulator/Debug/Release/-O/17.0",
    ]
    for name in ("swiftc", "swift-frontend", "clang", "ld", "libtool"):
        path = Path(os.fsdecode(command(*simulator, "--find", name)))
        inputs.extend((name, content(path.resolve(strict=True))))
    for name in ("bin/java", "lib/modules", "lib/server/libjvm.dylib"):
        inputs.extend((name, content((java_home / name).resolve(strict=True))))
    return inputs


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("resolved", type=Path)
    args = parser.parse_args()
    components = {}
    key = cache_key(
        Path.cwd(), args.resolved, Path.home() / ".konan/dependencies",
        host_toolchain(Path(os.environ["JAVA_HOME"])), component_digests=components,
    )
    print("Swift Export fingerprint: " + json.dumps({
        "runner_image_version": os.environ.get("ImageVersion", "unknown"),
        "components": components,
    }, sort_keys=True), file=sys.stderr)
    print(key)
