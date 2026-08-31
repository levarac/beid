#!/usr/bin/env python3
"""Run beid local tests quietly while retaining complete evidence."""

from __future__ import annotations

import argparse
from dataclasses import dataclass, field
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from typing import Callable, Iterable, Sequence
import uuid
import xml.etree.ElementTree as ET


REPO_ROOT = Path(__file__).resolve().parents[1]
ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
UDID_RE = re.compile(r"^[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$")


@dataclass
class Failure:
    name: str
    details: str
    identifier: str | None = None


@dataclass
class Counts:
    total: int = 0
    passed: int = 0
    failed: int = 0
    skipped: int = 0
    failures: list[Failure] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    bundles: dict[str, "Counts"] = field(default_factory=dict)

    def add(self, other: "Counts") -> None:
        self.total += other.total
        self.passed += other.passed
        self.failed += other.failed
        self.skipped += other.skipped
        self.failures.extend(other.failures)
        self.warnings.extend(other.warnings)


@dataclass
class ChildResult:
    returncode: int


@dataclass
class SimulatorEvidence:
    udid: str
    state: str
    erased: bool


def warning(message: str) -> str:
    return f"EVIDENCE WARNING: {message}"


def make_run_directory(repo_root: Path, platform: str) -> Path:
    root = Path(os.environ.get("BEID_LOCAL_TEST_RUN_ROOT", repo_root / "build" / "local-test-runs"))
    stamp = time.strftime("%Y%m%d-%H%M%S")
    path = (root / f"{stamp}-{platform}-{uuid.uuid4().hex[:8]}").resolve()
    path.mkdir(parents=True, exist_ok=False)
    return path


def run_primary_child(
    argv: Sequence[str],
    cwd: Path,
    raw_log: Path,
    env: dict[str, str],
    *,
    launcher: Callable[..., subprocess.CompletedProcess[str]] | None = None,
    announce: bool = True,
) -> ChildResult:
    raw_log = raw_log.resolve()
    raw_log.parent.mkdir(parents=True, exist_ok=True)
    if announce:
        print(f"Raw log: {raw_log}", flush=True)
    child_env = os.environ.copy()
    child_env.update(env)
    if launcher is not None:
        result = launcher(list(argv), cwd=str(cwd), env=child_env, text=True, capture_output=True)
        raw_log.write_text((result.stdout or "") + (result.stderr or ""), encoding="utf-8")
        return ChildResult(result.returncode)
    with raw_log.open("w", encoding="utf-8") as stream:
        process = subprocess.Popen(
            list(argv), cwd=str(cwd), env=child_env, text=True,
            stdout=stream, stderr=subprocess.STDOUT,
        )
        return ChildResult(process.wait())


def print_raw_log_on_failure(returncode: int, raw_log: Path) -> None:
    if returncode == 0:
        return
    print(f"\n===== COMPLETE RAW CHILD LOG: {raw_log.resolve()} =====")
    try:
        print(raw_log.read_text(encoding="utf-8", errors="replace"), end="")
    except OSError as error:
        print(warning(f"could not read raw child log: {error}"))
    print("===== END COMPLETE RAW CHILD LOG =====")


def shell_exit_code(returncode: int) -> int:
    return returncode if returncode >= 0 else 128 + abs(returncode)


def launch_error_code(error: OSError) -> int:
    return 127 if isinstance(error, FileNotFoundError) else 126


def guard_evidence(
    child_returncode: int,
    label: str,
    reader: Callable[[], object],
) -> tuple[object | None, list[str]]:
    """Keep evidence-read failures from replacing the test command result."""
    try:
        return reader(), []
    except Exception as error:
        return None, [
            warning(
                f"{label} failed after child exit {shell_exit_code(child_returncode)}: {error}"
            )
        ]


def validate_gradle_tasks(tasks: Sequence[str]) -> None:
    if not tasks:
        raise ValueError("at least one fully-qualified Gradle task is required")
    for task in tasks:
        if not re.fullmatch(r":[A-Za-z0-9_.-]+(?::[A-Za-z0-9_.-]+)+", task):
            raise ValueError(f"Gradle task must be fully qualified: {task!r}")


def android_command(repo_root: Path, tasks: Sequence[str], java_home: str) -> tuple[list[str], Path, dict[str, str]]:
    validate_gradle_tasks(tasks)
    return ["./gradlew", "--console=plain", "--stacktrace", *tasks], repo_root / "android", {"JAVA_HOME": java_home}


def parse_gradle_task_outcomes(log: str) -> dict[str, str]:
    outcomes: dict[str, str] = {}
    for raw_line in log.splitlines():
        line = ANSI_RE.sub("", raw_line).strip()
        match = re.fullmatch(r"> Task (:[^ ]+)(?: (UP-TO-DATE|FROM-CACHE|NO-SOURCE|FAILED|SKIPPED))?", line)
        if match:
            outcomes[match.group(1)] = match.group(2) or "EXECUTED"
    return outcomes


def snapshot_xml(paths: Iterable[Path]) -> dict[Path, tuple[int, int]]:
    snapshot: dict[Path, tuple[int, int]] = {}
    for path in paths:
        try:
            stat = path.stat()
            snapshot[path] = (stat.st_mtime_ns, stat.st_size)
        except OSError:
            pass
    return snapshot


def select_fresh_xml(paths: Iterable[Path], before: dict[Path, tuple[int, int]]) -> tuple[list[Path], list[Path]]:
    fresh: list[Path] = []
    stale: list[Path] = []
    for path in paths:
        try:
            stat = path.stat()
        except OSError:
            continue
        current = (stat.st_mtime_ns, stat.st_size)
        if path not in before or before[path] != current:
            fresh.append(path)
        else:
            stale.append(path)
    return fresh, stale


def parse_junit_files(paths: Iterable[Path]) -> Counts:
    aggregate = Counts()
    for path in paths:
        if not path.exists():
            aggregate.warnings.append(warning(f"missing JUnit XML: {path}"))
            continue
        try:
            root = ET.parse(path).getroot()
        except (ET.ParseError, OSError) as error:
            aggregate.warnings.append(warning(f"malformed/unreadable JUnit XML {path}: {error}"))
            continue
        if root.tag not in {"testsuite", "testsuites"}:
            aggregate.warnings.append(warning(f"unsupported JUnit root {root.tag!r}: {path}"))
            continue
        for case in root.iter("testcase"):
            aggregate.total += 1
            name = ".".join(filter(None, [case.get("classname", ""), case.get("name", "")]))
            skipped = case.find("skipped")
            failures = list(case.findall("failure")) + list(case.findall("error"))
            if skipped is not None:
                aggregate.skipped += 1
            elif failures:
                aggregate.failed += 1
                details = []
                for node in failures:
                    if node.get("message"):
                        details.append(node.get("message", ""))
                    if node.text and node.text.strip():
                        details.append(node.text.strip())
                aggregate.failures.append(Failure(name or "<unnamed test>", "\n".join(details)))
            else:
                aggregate.passed += 1
    return aggregate


def is_test_task(task: str) -> bool:
    return "test" in task.rsplit(":", 1)[-1].lower()


def junit_directory(repo_root: Path, task: str) -> Path:
    parts = task.strip(":").split(":")
    project_path = Path(*parts[:-1])
    external_project = repo_root / project_path
    project_dir = external_project if external_project.is_dir() else repo_root / "android" / project_path
    return project_dir / "build" / "test-results" / parts[-1]


def format_counts(counts: Counts) -> str:
    return f"total={counts.total} pass={counts.passed} fail={counts.failed} skip={counts.skipped}"


def format_android_task_summary(task: str, outcome: str, counts: Counts | None) -> str:
    if outcome == "NO-SOURCE":
        return f"{task}: NO-SOURCE — {warning('0 tests; no test evidence')}"
    if counts is None:
        return f"{task}: {outcome}"
    return f"{task}: {outcome} — {format_counts(counts)}"


def resolve_java_home(repo_root: Path) -> str:
    result = subprocess.run(
        [str(repo_root / "scripts" / "resolve_kmp_java_home.sh")],
        cwd=str(repo_root), text=True, capture_output=True,
    )
    if result.returncode != 0 or not result.stdout.strip():
        raise RuntimeError((result.stderr or result.stdout or "JDK resolver failed").strip())
    return result.stdout.strip().splitlines()[-1]


def run_android(args: argparse.Namespace) -> tuple[int, list[str]]:
    repo_root = REPO_ROOT
    run_dir = make_run_directory(repo_root, "android")
    raw_log = run_dir / "raw.log"
    raw_log.touch()
    print(f"Raw log: {raw_log.resolve()}", flush=True)
    validate_gradle_tasks(args.tasks)
    test_paths = {task: junit_directory(repo_root, task) for task in args.tasks if is_test_task(task)}
    before = {task: snapshot_xml(path.glob("**/*.xml")) for task, path in test_paths.items()}
    try:
        java_home = resolve_java_home(repo_root)
        argv, cwd, env = android_command(repo_root, args.tasks, java_home)
        child = run_primary_child(argv, cwd, raw_log, env, announce=False)
    except OSError as error:
        print(warning(f"command launch failed: {error}"))
        return launch_error_code(error), []
    except (RuntimeError, ValueError) as error:
        print(warning(str(error)))
        return 126, []

    warnings: list[str] = []
    log_value, read_warnings = guard_evidence(
        child.returncode,
        "raw Gradle log read",
        lambda: raw_log.read_text(encoding="utf-8", errors="replace"),
    )
    warnings.extend(read_warnings)
    log = str(log_value) if log_value is not None else ""
    outcomes_value, outcome_warnings = guard_evidence(
        child.returncode,
        "Gradle task outcome parser",
        lambda: parse_gradle_task_outcomes(log),
    )
    warnings.extend(outcome_warnings)
    outcomes = outcomes_value if isinstance(outcomes_value, dict) else {}
    aggregate = Counts()
    for task in args.tasks:
        outcome = outcomes.get(task, "UNKNOWN")
        counts: Counts | None = None
        if outcome == "UNKNOWN":
            warnings.append(warning(f"requested task has no parsed Gradle outcome: {task}"))
        if is_test_task(task):
            if outcome == "NO-SOURCE":
                counts = Counts()
                warnings.append(warning(f"{task} ran 0 tests (NO-SOURCE); not GREEN"))
            else:
                candidates = sorted(test_paths[task].glob("**/*.xml"))
                fresh, stale = select_fresh_xml(candidates, before[task])
                if stale:
                    warnings.append(warning(f"ignored {len(stale)} stale JUnit XML file(s) for {task}"))
                if not fresh:
                    warnings.append(warning(f"no fresh JUnit XML for {task}"))
                counts = parse_junit_files(fresh)
                warnings.extend(counts.warnings)
                aggregate.add(counts)
        print(format_android_task_summary(task, outcome, counts))
        if counts:
            for failure in counts.failures:
                print(f"FAILED: {failure.name}\n{failure.details}")
    print(f"Android aggregate: {format_counts(aggregate)}")
    print_raw_log_on_failure(child.returncode, raw_log)
    return shell_exit_code(child.returncode), warnings


def ios_command(repo_root: Path, udid: str, result_bundle: Path, action: str, only_testing: Sequence[str]) -> list[str]:
    argv = [
        "xcodebuild", "-project", str(repo_root / "ios" / "Beid.xcodeproj"),
        "-scheme", "Beid", "-destination", f"platform=iOS Simulator,id={udid}",
        "-resultBundlePath", str(result_bundle),
    ]
    argv.extend(f"-only-testing:{test}" for test in only_testing)
    argv.append(action)
    return argv


def _run_capture(argv: Sequence[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(list(argv), text=True, capture_output=True)


def _require_success(result: subprocess.CompletedProcess[str], description: str) -> None:
    if result.returncode != 0:
        raise RuntimeError(f"{description} failed ({result.returncode}): {(result.stderr or result.stdout).strip()}")


def simulator_state(udid: str, payload: str) -> str:
    data = json.loads(payload)
    for devices in data.get("devices", {}).values():
        for device in devices:
            if device.get("udid") == udid:
                return str(device.get("state", "Unknown"))
    return "Not found"


def prepare_simulator(udid: str, erase: bool, *, runner: Callable[..., subprocess.CompletedProcess[str]] = _run_capture) -> SimulatorEvidence:
    if erase:
        shutdown = runner(["xcrun", "simctl", "shutdown", udid])
        if shutdown.returncode not in {0, 149}:
            _require_success(shutdown, "simulator shutdown")
        for command in (["xcrun", "simctl", "erase", udid], ["xcrun", "simctl", "boot", udid], ["xcrun", "simctl", "bootstatus", udid, "-b"]):
            _require_success(runner(command), f"simulator {command[2]}")
    listing = runner(["xcrun", "simctl", "list", "devices", "--json"])
    _require_success(listing, "simulator state query")
    return SimulatorEvidence(udid, simulator_state(udid, listing.stdout), erase)


def parse_json_evidence(payload: str | None, label: str) -> tuple[object | None, list[str]]:
    if payload is None:
        return None, [warning(f"missing {label} JSON")]
    try:
        return json.loads(payload), []
    except (json.JSONDecodeError, TypeError) as error:
        return None, [warning(f"malformed {label} JSON: {error}")]


def _messages(node: dict[str, object]) -> str:
    values: list[str] = []
    for key in ("failureMessages", "failureMessage", "message"):
        value = node.get(key)
        if isinstance(value, list):
            values.extend(str(item.get("message", item) if isinstance(item, dict) else item) for item in value)
        elif value:
            values.append(str(value))
    return "\n".join(values)


def parse_xcresult_tests(payload: object) -> Counts:
    result = Counts()

    def walk(node: object, bundle: str | None = None) -> None:
        if isinstance(node, list):
            for item in node:
                walk(item, bundle)
            return
        if not isinstance(node, dict):
            return
        node_type = str(node.get("nodeType", node.get("type", "")))
        next_bundle = bundle
        if "bundle" in node_type.lower():
            next_bundle = str(node.get("name", "<unnamed bundle>"))
            result.bundles.setdefault(next_bundle, Counts())
        if node_type.lower() == "test case":
            status = str(node.get("result", node.get("testStatus", "Unknown"))).lower()
            targets = [result]
            if next_bundle:
                targets.append(result.bundles.setdefault(next_bundle, Counts()))
            for target in targets:
                target.total += 1
                if status in {"passed", "success"}:
                    target.passed += 1
                elif status in {"skipped", "expected failure"}:
                    target.skipped += 1
                else:
                    target.failed += 1
            if status not in {"passed", "success", "skipped", "expected failure"}:
                result.failures.append(Failure(str(node.get("name", "<unnamed test>")), _messages(node), str(node.get("nodeIdentifier")) if node.get("nodeIdentifier") else None))
        for key in ("children", "testNodes", "subtests"):
            if key in node:
                walk(node[key], next_bundle)

    walk(payload)
    return result


def validate_xcresult_summary(summary: object, tests: Counts) -> list[str]:
    if not isinstance(summary, dict):
        return [warning("xcresult summary is not an object")]
    warnings: list[str] = []
    total = int(summary.get("totalTestCount", 0) or 0)
    if total == 0:
        warnings.append(warning("xcresult summary reports 0 tests; not GREEN"))
    expected = (total, int(summary.get("passedTests", 0) or 0), int(summary.get("failedTests", 0) or 0), int(summary.get("skippedTests", 0) or 0))
    actual = (tests.total, tests.passed, tests.failed, tests.skipped)
    if expected != actual:
        warnings.append(warning(f"xcresult summary/tree count mismatch: summary={expected} tree={actual}"))
    return warnings


def summary_failures(summary: object) -> list[Failure]:
    if not isinstance(summary, dict):
        return []
    failures: list[Failure] = []
    for item in summary.get("testFailures", []) or []:
        if isinstance(item, dict):
            failures.append(Failure(str(item.get("testName", "<unnamed test>")), str(item.get("failureText", item.get("message", ""))), str(item.get("testIdentifier")) if item.get("testIdentifier") else None))
    return failures


def xcresult_json(result_bundle: Path, kind: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["xcrun", "xcresulttool", "get", "test-results", kind, "--path", str(result_bundle), "--compact"], text=True, capture_output=True)


def run_ios(args: argparse.Namespace) -> tuple[int, list[str]]:
    repo_root = REPO_ROOT
    run_dir = make_run_directory(repo_root, "ios")
    raw_log = run_dir / "raw.log"
    result_bundle = run_dir / "result.xcresult"
    raw_log.touch()
    print(f"Raw log: {raw_log.resolve()}", flush=True)
    warnings: list[str] = []
    try:
        simulator = prepare_simulator(args.udid, args.erase_simulator)
        print(
            f"Simulator: UDID={simulator.udid} state={simulator.state} "
            f"erased={'yes' if simulator.erased else 'no'}"
        )
        if result_bundle.exists():
            raise RuntimeError(f"refusing to reuse existing xcresult: {result_bundle}")
        child = run_primary_child(ios_command(repo_root, args.udid, result_bundle, args.action, args.only_testing), repo_root, raw_log, {}, announce=False)
    except OSError as error:
        print(warning(f"command launch failed: {error}"))
        return launch_error_code(error), warnings
    except (RuntimeError, ValueError, json.JSONDecodeError) as error:
        print(warning(str(error)))
        return 126, warnings

    summary_obj: object | None = None
    tests_obj: object | None = None
    if not result_bundle.exists():
        warnings.append(warning(f"missing xcresult bundle: {result_bundle}"))
    else:
        for kind, filename in (("summary", "summary.json"), ("tests", "tests.json")):
            parsed = xcresult_json(result_bundle, kind)
            if parsed.returncode != 0:
                warnings.append(warning(f"xcresulttool {kind} failed: {(parsed.stderr or parsed.stdout).strip()}"))
                continue
            (run_dir / filename).write_text(parsed.stdout, encoding="utf-8")
            value, parse_warnings = parse_json_evidence(parsed.stdout, f"xcresult {kind}")
            warnings.extend(parse_warnings)
            if kind == "summary": summary_obj = value
            else: tests_obj = value

    counts_value, count_warnings = guard_evidence(
        child.returncode,
        "xcresult test tree parser",
        lambda: parse_xcresult_tests(tests_obj) if tests_obj is not None else Counts(),
    )
    warnings.extend(count_warnings)
    counts = counts_value if isinstance(counts_value, Counts) else Counts()
    if summary_obj is not None:
        validation_value, validation_warnings = guard_evidence(
            child.returncode,
            "xcresult summary validator",
            lambda: validate_xcresult_summary(summary_obj, counts),
        )
        warnings.extend(validation_warnings)
        if isinstance(validation_value, list):
            warnings.extend(validation_value)
    else:
        warnings.append(warning("no structured xcresult summary available"))
    print(f"iOS aggregate: {format_counts(counts)}")
    for bundle, bundle_counts in counts.bundles.items():
        print(f"iOS bundle {bundle}: {format_counts(bundle_counts)}")
    failures = counts.failures or summary_failures(summary_obj)
    for failure in failures:
        print(f"FAILED: {failure.name}\n{failure.details or '<no structured message>'}")
        if failure.identifier and result_bundle.exists():
            detail = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "test-details", "--test-id", failure.identifier, "--path", str(result_bundle), "--compact"], text=True, capture_output=True)
            if detail.returncode == 0:
                detail_path = run_dir / f"test-details-{len(list(run_dir.glob('test-details-*.json'))) + 1}.json"
                detail_path.write_text(detail.stdout, encoding="utf-8")
                print(detail.stdout)
            else:
                warnings.append(warning(f"test-details unavailable for {failure.name}: {(detail.stderr or detail.stdout).strip()}"))
    print(f"Retained xcresult: {result_bundle.resolve()}")
    print_raw_log_on_failure(child.returncode, raw_log)
    return shell_exit_code(child.returncode), warnings


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="platform", required=True)
    android = subparsers.add_parser("android", help="run fully-qualified Gradle tasks")
    android.add_argument("tasks", nargs="+")
    ios = subparsers.add_parser("ios", help="run iOS tests on one exact Simulator")
    ios.add_argument("--udid", required=True)
    state = ios.add_mutually_exclusive_group(required=True)
    state.add_argument("--erase-simulator", action="store_true")
    state.add_argument("--keep-simulator-state", action="store_true")
    ios.add_argument("--action", choices=("test", "test-without-building"), default="test")
    ios.add_argument("--only-testing", action="append", default=[])
    return parser


def parse_args(parser: argparse.ArgumentParser, argv: Sequence[str]) -> argparse.Namespace:
    args = parser.parse_args(list(argv))
    if args.platform == "ios" and not UDID_RE.fullmatch(args.udid):
        parser.error("--udid must be one exact Simulator UUID, not a name or generic destination")
    if args.platform == "android":
        try:
            validate_gradle_tasks(args.tasks)
        except ValueError as error:
            parser.error(str(error))
    return args


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(build_parser(), argv if argv is not None else sys.argv[1:])
    child_rc, warnings = run_android(args) if args.platform == "android" else run_ios(args)
    for item in warnings:
        print(item)
    return child_rc


if __name__ == "__main__":
    raise SystemExit(main())
