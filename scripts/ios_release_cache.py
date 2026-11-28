"""Authenticate optional Simulator cache payloads against their release-scoped GitHub keys."""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
from functools import lru_cache
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import time

RELEASE_REF = "refs/heads/release/1.1.0"
HEX = r"[0-9a-f]{64}"
WEEK = r"[0-9]{4}-W[0-9]{2}"


def archive_version(paths, compression):
    # actions/cache 0057852b, getCacheVersion on macOS (cross-OS archives disabled).
    return hashlib.sha256("|".join([*paths, compression, "1.0"]).encode()).hexdigest()


@lru_cache(maxsize=1)
def compression_method():
    try:
        result = subprocess.run(["zstd", "--quiet", "--version"], capture_output=True, check=False)
    except FileNotFoundError:
        return "gzip"
    return "zstd-without-long" if result.stdout.strip() else "gzip"


def dependency_paths(kind):
    if kind == "dist":
        return ["~/.gradle/wrapper/dists"]
    if kind == "kmp":
        return ["~/.gradle/caches/modules-2/files-2.1", "~/.konan/dependencies"]
    if kind == "spm":
        root = os.environ["SPM_SOURCE_ROOT"]
        return [root + "/checkouts", root + "/repositories"]
    raise ValueError("unsupported dependency cache")


def expected_version(kind):
    if kind in ("cas", "export"):
        paths = [os.environ["RUNNER_TEMP"] + "/beid-release-cache/" + kind + ".tar"]
    else:
        paths = dependency_paths(kind)
    return archive_version(paths, compression_method())


def release_keys(entries, prefix, kind, version):
    suffix = (WEEK + "-" if kind == "cas" else "") + HEX
    return [e["key"] for e in entries if e.get("ref") == RELEASE_REF and e.get("version") == version
            and re.fullmatch(re.escape(prefix) + suffix, e.get("key", ""))]


def digest(path):
    with path.open("rb") as stream:
        result = hashlib.sha256()
        for part in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(part)
        return result.hexdigest()


def pack(source, archive):
    if source.is_symlink() or not source.is_dir():
        raise ValueError("missing cache directory")
    files = sorted(source.rglob("*"))
    if not any(p.is_file() for p in files):
        raise ValueError("empty cache")
    archive.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, "x", dereference=True) as writer:
        for p in files:
            if p.is_symlink() or not (p.is_file() or p.is_dir()):
                raise ValueError("unexpected cache member")
            writer.add(p, arcname=str(p.relative_to(source)), recursive=False)
    return digest(archive)


def restore(archive, dest, matched, trusted):
    if not matched or matched not in trusted or not re.fullmatch(HEX, matched.rsplit("-", 1)[-1]):
        raise ValueError("cache key absent from release inventory")
    if archive.is_symlink() or not archive.is_file() or digest(archive) != matched.rsplit("-", 1)[-1]:
        raise ValueError("cache payload does not match the release digest")
    if os.path.lexists(dest):
        raise ValueError("cache destination already exists")
    dest.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=dest.parent) as temp:
        stage = Path(temp) / "entry"
        stage.mkdir()
        with tarfile.open(archive, "r:") as reader:
            for m in reader:
                if not (m.isfile() or m.isdir()):
                    raise ValueError("unexpected archive member")
                reader.extract(m, stage, filter="data")
        stage.rename(dest)


def entries_for(prefix):
    repo = os.environ["GITHUB_REPOSITORY"]
    cmd = ["gh", "api", "--method", "GET", f"repos/{repo}/actions/caches",
           "-f", "ref=" + RELEASE_REF, "-f", "key=" + prefix,
           "-f", "sort=created_at", "-f", "direction=desc", "-f", "per_page=100"]
    data = json.loads(subprocess.check_output(cmd, timeout=30))
    return [entry for entry in data["actions_caches"] if entry.get("ref") == RELEASE_REF]


def inventory(prefix, kind):
    return release_keys(entries_for(prefix), prefix, kind, expected_version(kind))


@contextmanager
def plan_phase(number):
    """Log only the phase number and elapsed milliseconds, including on failure.

    1 = host toolchain, 2 = Gradle resolution, 3 = Swift Export fingerprint,
    4 = CAS inventory, 5 = export inventory. Skipped phases have no line.
    """
    start = time.monotonic_ns()
    try:
        yield
    finally:
        print(number, (time.monotonic_ns() - start) // 1_000_000, flush=True)


def make_plan(root):
    from scripts.ios_swift_export_key import host_toolchain, add_record

    host = hashlib.sha256()
    with plan_phase(1):
        for item in host_toolchain(Path(os.environ["JAVA_HOME"])):
            add_record(host, item)
    week = datetime.now(timezone.utc).strftime("%G-W%V")
    toolchain = host.hexdigest()
    export_digest = ""
    resolved = root / "inputs.json"
    try:
        with plan_phase(2):
            subprocess.run(["./gradlew", "-q", "-I", "../scripts/ios_swift_export_inputs.gradle",
                            ":shared:fingerprintSwiftExportInputs", "-PbeidExportInputsFile=" + str(resolved)],
                           cwd="android", check=True, env={k: v for k, v in os.environ.items() if k != "GH_TOKEN"})
        from scripts.ios_swift_export_key import cache_key
        with plan_phase(3):
            export_digest = cache_key(Path.cwd(), resolved, Path.home() / ".konan/dependencies", [toolchain])
    except (OSError, ValueError, subprocess.SubprocessError):
        print("Swift Export fingerprint unavailable. Use the normal Kotlin build.")
    plan = {"export_digest": export_digest}
    for phase, kind in enumerate(("cas", "export"), start=4):
        if kind == "export" and not export_digest:
            continue
        prefix = f"beid-ios-{kind}-v1-{toolchain}-"
        if kind == "export":
            prefix += export_digest + "-"
        write_prefix = prefix + (week + "-" if kind == "cas" else "")
        with plan_phase(phase):
            trusted = inventory(prefix, kind)
        plan[kind] = dict(prefix=prefix, write_prefix=write_prefix, keys=trusted,
                          fresh=any(k.startswith(write_prefix) for k in trusted))
    return plan


def dependencies(*, require_restore_hit=False):
    fresh = {}
    for name in ("dist", "kmp", "spm"):
        key = os.environ[name.upper()]
        if not key.startswith("beid-ios-"):
            raise ValueError("missing dependency key")
        version = expected_version(name)
        available = any(entry["key"] == key and entry.get("version") == version for entry in entries_for(key))
        hit = os.environ.get(name.upper() + "_HIT") == "true"
        fresh[name] = available and (hit or not require_restore_hit)
    return fresh


def confirm(plan):
    for attempt in range(5):
        present = dependencies()
        for kind in ("cas", "export"):
            if kind not in plan:
                raise ValueError(f"missing producer fingerprint for {kind}")
            item = plan[kind]
            present[kind] = any(key.startswith(item["write_prefix"]) for key in inventory(item["prefix"], kind))
        if all(present.values()):
            print("Release scope confirmed: " + ", ".join(present))
            return
        if attempt < 4:
            time.sleep(5)
    raise ValueError("missing release cache entries: " + ", ".join(k for k in present if not present[k]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("op", choices=["plan", "restore", "pack", "dependencies", "confirm"])
    parser.add_argument("--kind", choices=["cas", "export"])
    parser.add_argument("--source", type=Path)
    parser.add_argument("--matched")
    args = parser.parse_args()
    root = Path(os.environ["RUNNER_TEMP"]) / "beid-release-cache"
    root.mkdir(exist_ok=True)
    plan_file = root / "plan.json"
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as outputs:
        if args.op == "dependencies":
            present = dependencies(require_restore_hit=True)
            for name, available in {**present, "all": all(present.values())}.items():
                print(f"{name}={str(available).lower()}", file=outputs)
            return
        if args.op == "confirm":
            confirm(json.loads(plan_file.read_text()))
            return
        if args.op == "plan":
            plan = make_plan(root)
            plan_file.write_text(json.dumps(plan))
            for kind in ("cas", "export"):
                if item := plan.get(kind):
                    print(f"{kind}_prefix={item['prefix']}", file=outputs)
                    print(f"{kind}_key={next(iter(item['keys']), '')}", file=outputs)
                    print(f"{kind}_fresh={str(item['fresh']).lower()}", file=outputs)
            print("export_digest=" + plan["export_digest"], file=outputs)
            return
        kind = args.kind
        item = json.loads(plan_file.read_text())[kind]
        archive = root / f"{kind}.tar"
        if args.op == "restore":
            restore(archive, root / kind, args.matched, item["keys"])
            print("ready=true", file=outputs)
        else:
            value = pack(args.source, archive)
            print(f"key={item['write_prefix']}{value}", file=outputs)


if __name__ == "__main__":
    main()
