"""Contract tests for scripts/ci_derived_data.sh (persistent DerivedData on the emi lanes).

The script is what both `pr-ci-ios-macos.yml` and `main-ios-release-build.yml`
call; these tests pin the two things the workflows rely on and cannot check
themselves:

- `resolve` derives ONE key from four inputs (Xcode build version, XcodeGen pin,
  Package.resolved content, manual bump), places the DerivedData under the
  runner user per runner, reports cold/warm, and prunes to the three most
  recently used keys.
- `build` wipes the DerivedData on failure and retries exactly once when the
  failed attempt was warm; a cold failure is not retried, because a clean
  build that failed has nothing stale to heal.

`xcodebuild` is a fake on PATH. The script is run under /bin/bash on purpose:
on the runner that is macOS bash 3.2, on the sanity job it is bash 5, and the
script must behave the same under both.
"""

import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).parents[2]
SCRIPT = REPO_ROOT / "scripts" / "ci_derived_data.sh"

FAKE_XCODEBUILD = r"""#!/bin/bash
# Fake xcodebuild for tests. `-version` prints a build version taken from the
# environment; any other invocation counts the call, writes a sentinel into the
# -derivedDataPath it was given, and fails while the call count is <= the
# number in $FAKE_XCODEBUILD_STATE/fail_first_n.
state="${FAKE_XCODEBUILD_STATE:?}"
if [ "${1:-}" = "-version" ]; then
  printf 'Xcode 26.6\nBuild version %s\n' "${FAKE_XCODE_BUILD:-17F113}"
  exit 0
fi
calls=0
[ -f "$state/calls" ] && calls="$(cat "$state/calls")"
calls=$((calls + 1))
printf '%s\n' "$calls" > "$state/calls"
derived=""
while [ $# -gt 0 ]; do
  if [ "$1" = "-derivedDataPath" ]; then derived="$2"; shift; fi
  shift
done
if [ -n "$derived" ]; then
  mkdir -p "$derived"
  printf 'call %s\n' "$calls" > "$derived/sentinel-call-$calls"
fi
fail_first_n=0
[ -f "$state/fail_first_n" ] && fail_first_n="$(cat "$state/fail_first_n")"
if [ "$calls" -le "$fail_first_n" ]; then
  echo "fake xcodebuild: failing call $calls" >&2
  exit 65
fi
echo "fake xcodebuild: call $calls ok"
exit 0
"""

PACKAGE_RESOLVED = '{"pins": [{"identity": "barnard", "state": {"revision": "d382de87"}}], "version": 2}\n'


class Sandbox:
    """A temp HOME, a temp repo checkout with the key inputs, and a fake xcodebuild."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.home = root / "home"
        self.workspace = root / "workspace"
        self.bin = root / "bin"
        self.state = root / "state"
        self.github_env = root / "github_env"
        self.summary = root / "summary.md"
        for directory in (self.home, self.workspace, self.bin, self.state):
            directory.mkdir(parents=True)
        self.github_env.touch()
        self.summary.touch()
        ci_scripts = self.workspace / "ios" / "ci_scripts"
        ci_scripts.mkdir(parents=True)
        (ci_scripts / "XCODEGEN_VERSION").write_text("2.45.3\n", encoding="utf-8")
        (ci_scripts / "DERIVED_DATA_CACHE_BUMP").write_text("1\n", encoding="utf-8")
        resolved = (
            self.workspace
            / "ios/Beid.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        )
        resolved.parent.mkdir(parents=True)
        resolved.write_text(PACKAGE_RESOLVED, encoding="utf-8")
        fake = self.bin / "xcodebuild"
        fake.write_text(FAKE_XCODEBUILD, encoding="utf-8")
        fake.chmod(0o755)

    def env(self, **overrides: str) -> dict:
        env = {
            "PATH": f"{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": str(self.home),
            "GITHUB_WORKSPACE": str(self.workspace),
            "GITHUB_REPOSITORY": "thegreeting/beid",
            "RUNNER_NAME": "emi",
            "GITHUB_ENV": str(self.github_env),
            "GITHUB_STEP_SUMMARY": str(self.summary),
            "FAKE_XCODEBUILD_STATE": str(self.state),
            "FAKE_XCODE_BUILD": "17F113",
        }
        env.update(overrides)
        return env

    def run(self, *args: str, env: dict, check: bool = True) -> subprocess.CompletedProcess:
        result = subprocess.run(
            ["/bin/bash", str(SCRIPT), *args],
            cwd=self.workspace,
            env=env,
            capture_output=True,
            text=True,
        )
        if check and result.returncode != 0:
            raise AssertionError(
                f"{args} exited {result.returncode}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
            )
        return result

    def github_env_values(self) -> dict:
        values = {}
        for line in self.github_env.read_text(encoding="utf-8").splitlines():
            if "=" in line:
                name, value = line.split("=", 1)
                values[name] = value
        return values

    def resolve(self, env: dict) -> dict:
        self.github_env.write_text("", encoding="utf-8")
        self.run("resolve", env=env)
        values = self.github_env_values()
        for name in ("CI_DERIVED_DATA", "CI_DERIVED_DATA_KEY", "CI_DERIVED_DATA_STATE"):
            if name not in values:
                raise AssertionError(f"{name} not exported; GITHUB_ENV was:\n{self.github_env.read_text()}")
        return values

    def build_env(self, resolved: dict, env: dict) -> dict:
        merged = dict(env)
        merged.update(resolved)
        return merged

    def calls(self) -> int:
        calls = self.state / "calls"
        return int(calls.read_text(encoding="utf-8")) if calls.exists() else 0

    def fail_first(self, n: int) -> None:
        (self.state / "fail_first_n").write_text(f"{n}\n", encoding="utf-8")

    def cache_runner_root(self) -> Path:
        return self.home / "Library/Caches/ci-derived-data/thegreeting-beid/emi"


class CiDerivedDataTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.sandbox = Sandbox(Path(self._tmp.name))
        self.addCleanup(self._tmp.cleanup)

    # --- resolve -------------------------------------------------------------

    def test_resolve_places_derived_data_under_runner_user_per_runner_and_starts_cold(self) -> None:
        values = self.sandbox.resolve(self.sandbox.env())

        path = Path(values["CI_DERIVED_DATA"])
        self.assertEqual(path.parent, self.sandbox.cache_runner_root())
        self.assertEqual(path.name, values["CI_DERIVED_DATA_KEY"])
        self.assertRegex(values["CI_DERIVED_DATA_KEY"], r"^[0-9a-f]{16}$")
        self.assertEqual(values["CI_DERIVED_DATA_STATE"], "cold")
        self.assertTrue((path / ".last-used").is_file())
        summary = self.sandbox.summary.read_text(encoding="utf-8")
        self.assertIn("### DerivedData", summary)
        self.assertIn("cold", summary)
        # The key inputs are named in the summary so a reader can see what invalidates it.
        self.assertIn("17F113", summary)
        self.assertIn("2.45.3", summary)

    def test_resolve_is_warm_on_the_next_run_with_the_same_inputs(self) -> None:
        first = self.sandbox.resolve(self.sandbox.env())
        second = self.sandbox.resolve(self.sandbox.env())

        self.assertEqual(first["CI_DERIVED_DATA_KEY"], second["CI_DERIVED_DATA_KEY"])
        self.assertEqual(second["CI_DERIVED_DATA_STATE"], "warm")

    def test_key_changes_when_any_one_input_changes(self) -> None:
        baseline = self.sandbox.resolve(self.sandbox.env())["CI_DERIVED_DATA_KEY"]

        xcode = self.sandbox.resolve(self.sandbox.env(FAKE_XCODE_BUILD="17G100"))["CI_DERIVED_DATA_KEY"]

        (self.sandbox.workspace / "ios/ci_scripts/XCODEGEN_VERSION").write_text("2.46.0\n", encoding="utf-8")
        xcodegen = self.sandbox.resolve(self.sandbox.env())["CI_DERIVED_DATA_KEY"]
        (self.sandbox.workspace / "ios/ci_scripts/XCODEGEN_VERSION").write_text("2.45.3\n", encoding="utf-8")

        resolved_path = (
            self.sandbox.workspace
            / "ios/Beid.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        )
        resolved_path.write_text(PACKAGE_RESOLVED.replace("d382de87", "0000000"), encoding="utf-8")
        package = self.sandbox.resolve(self.sandbox.env())["CI_DERIVED_DATA_KEY"]
        resolved_path.write_text(PACKAGE_RESOLVED, encoding="utf-8")

        (self.sandbox.workspace / "ios/ci_scripts/DERIVED_DATA_CACHE_BUMP").write_text("2\n", encoding="utf-8")
        bump = self.sandbox.resolve(self.sandbox.env())["CI_DERIVED_DATA_KEY"]

        keys = {baseline, xcode, xcodegen, package, bump}
        self.assertEqual(len(keys), 5, f"keys collided: {keys}")

    def test_resolve_prunes_to_the_three_most_recently_used_keys(self) -> None:
        runner_root = self.sandbox.cache_runner_root()
        now = time.time()
        for index, name in enumerate(("aaaa000000000001", "aaaa000000000002", "aaaa000000000003", "aaaa000000000004")):
            marker = runner_root / name / ".last-used"
            marker.parent.mkdir(parents=True)
            marker.touch()
            stamp = now - (10 - index) * 3600  # 0001 oldest ... 0004 newest
            os.utime(marker, (stamp, stamp))
        foreign = runner_root / "not-a-cache-dir"
        foreign.mkdir()
        (foreign / "keep-me").touch()

        values = self.sandbox.resolve(self.sandbox.env())

        remaining = sorted(p.name for p in runner_root.iterdir())
        self.assertEqual(
            remaining,
            sorted(["aaaa000000000003", "aaaa000000000004", values["CI_DERIVED_DATA_KEY"], "not-a-cache-dir"]),
        )
        self.assertTrue((foreign / "keep-me").exists(), "directories without a marker are not ours to delete")

    def test_resolve_refuses_to_run_outside_a_checkout_with_the_key_inputs(self) -> None:
        (self.sandbox.workspace / "ios/ci_scripts/DERIVED_DATA_CACHE_BUMP").unlink()

        result = self.sandbox.run("resolve", env=self.sandbox.env(), check=False)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("DERIVED_DATA_CACHE_BUMP", result.stderr)

    # --- build ---------------------------------------------------------------

    def _build(self, resolved: dict, env: dict, label: str = "Build for testing") -> subprocess.CompletedProcess:
        return self.sandbox.run(
            "build",
            label,
            "--",
            "xcodebuild",
            "-scheme",
            "Beid",
            "-derivedDataPath",
            resolved["CI_DERIVED_DATA"],
            "build-for-testing",
            env=self.sandbox.build_env(resolved, env),
            check=False,
        )

    def test_build_that_passes_runs_once_and_summary_says_incremental(self) -> None:
        env = self.sandbox.env()
        self.sandbox.resolve(env)
        resolved = self.sandbox.resolve(env)  # warm

        result = self._build(resolved, env, label="Build Release for device")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.sandbox.calls(), 1)
        summary = self.sandbox.summary.read_text(encoding="utf-8")
        self.assertIn("Build Release for device", summary)
        self.assertIn("incremental", summary)
        self.assertIn("warm", summary)

    def test_build_that_passes_cold_still_says_incremental_so_nobody_quotes_it_as_a_cold_number(self) -> None:
        env = self.sandbox.env()
        resolved = self.sandbox.resolve(env)  # cold

        result = self._build(resolved, env)

        self.assertEqual(result.returncode, 0, result.stderr)
        summary = self.sandbox.summary.read_text(encoding="utf-8")
        self.assertIn("incremental", summary)
        self.assertIn("cold", summary)

    def test_warm_failure_wipes_derived_data_and_retries_exactly_once(self) -> None:
        env = self.sandbox.env()
        self.sandbox.resolve(env)
        resolved = self.sandbox.resolve(env)  # warm
        derived = Path(resolved["CI_DERIVED_DATA"])
        self.sandbox.fail_first(1)

        result = self._build(resolved, env)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.sandbox.calls(), 2)
        self.assertFalse((derived / "sentinel-call-1").exists(), "the first attempt's output survived the wipe")
        self.assertTrue((derived / "sentinel-call-2").exists())
        self.assertTrue((derived / ".last-used").is_file(), "a passing retry leaves the cache warm for the next run")
        summary = self.sandbox.summary.read_text(encoding="utf-8")
        self.assertIn("clean retry", summary)

    def test_warm_failure_twice_fails_after_one_retry_and_leaves_no_cache(self) -> None:
        env = self.sandbox.env()
        self.sandbox.resolve(env)
        resolved = self.sandbox.resolve(env)  # warm
        derived = Path(resolved["CI_DERIVED_DATA"])
        self.sandbox.fail_first(2)

        result = self._build(resolved, env)

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.sandbox.calls(), 2, "exactly one retry, never two")
        self.assertFalse(derived.exists(), "a build that failed twice leaves nothing for the next run to trust")
        summary = self.sandbox.summary.read_text(encoding="utf-8")
        self.assertIn("failed", summary)

    def test_cold_failure_is_not_retried_but_the_cache_is_still_wiped(self) -> None:
        env = self.sandbox.env()
        resolved = self.sandbox.resolve(env)  # cold
        derived = Path(resolved["CI_DERIVED_DATA"])
        self.sandbox.fail_first(1)

        result = self._build(resolved, env)

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.sandbox.calls(), 1, "a clean build that failed has nothing stale to heal")
        self.assertFalse(derived.exists())
        summary = self.sandbox.summary.read_text(encoding="utf-8")
        self.assertIn("no retry", summary)

    def test_build_refuses_to_wipe_a_path_outside_the_cache_root(self) -> None:
        env = self.sandbox.env()
        resolved = self.sandbox.resolve(env)
        elsewhere = self.sandbox.root / "elsewhere"
        elsewhere.mkdir()
        (elsewhere / "precious").write_text("do not delete\n", encoding="utf-8")
        resolved["CI_DERIVED_DATA"] = str(elsewhere)
        resolved["CI_DERIVED_DATA_STATE"] = "warm"
        self.sandbox.fail_first(1)

        result = self._build(resolved, env)

        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((elsewhere / "precious").exists())
        self.assertIn("refus", result.stderr.lower())

    def test_wipe_itself_refuses_an_out_of_root_path_even_when_called_in_a_conditional_context(self) -> None:
        """Defence in depth for the guard inside wipe (checker finding F3 on gh#520).

        cmd_build rejects a bad CI_DERIVED_DATA at its entry, so the other
        refusal test never reaches the guard inside wipe. Here the script is
        sourced and wipe is called directly as `wipe <path> || true`: inside a
        function invoked in a conditional context bash suppresses `set -e`, so
        the only thing standing between a rejected path and `rm -rf` is wipe
        checking guard_cache_path's return value itself.
        """
        env = self.sandbox.env()
        elsewhere = self.sandbox.root / "elsewhere"
        elsewhere.mkdir()
        (elsewhere / "precious").write_text("do not delete\n", encoding="utf-8")

        result = subprocess.run(
            [
                "/bin/bash",
                "-c",
                'source "$1"; wipe "$2" || true; test -e "$2/precious" && echo kept',
                "bash",
                str(SCRIPT),
                str(elsewhere),
            ],
            cwd=self.sandbox.workspace,
            env=env,
            capture_output=True,
            text=True,
        )

        self.assertTrue((elsewhere / "precious").exists(), result.stderr)
        self.assertIn("kept", result.stdout)
        self.assertIn("refus", result.stderr.lower())
        self.assertNotIn("wiping", result.stderr)

    def test_build_requires_resolve_to_have_run(self) -> None:
        env = self.sandbox.env()

        result = self.sandbox.run("build", "x", "--", "xcodebuild", "build", env=env, check=False)

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.sandbox.calls(), 0)
        self.assertIn("CI_DERIVED_DATA", result.stderr)


if __name__ == "__main__":
    unittest.main()
