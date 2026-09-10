"""Contract tests for the shared git-height build position (beid#491).

The guard being witnessed is **"refuse a shallow clone"**, not "refuse an empty
height". That distinction is the whole feature: on a shallow clone
`git rev-list --count HEAD` exits 0 and prints a plausible smaller number, so a
build would ship a wrong build position that looks exactly like a right one.
`test_a_shallow_clone_truncates_silently` establishes that premise by
measurement rather than assertion.

The Android guard is witnessed **behaviourally** — the workflow step's own shell
is extracted and executed against a real shallow clone — at the cheapest layer
where it can still fail. Deleting the shallowness check makes that test go red
while everything else stays green.
"""

import re
import subprocess
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

REPO_ROOT = Path(__file__).resolve().parents[2]
PLAY_WORKFLOW = REPO_ROOT / ".github/workflows/internal-google-play.yml"
SIGN_SCRIPT = REPO_ROOT / "scripts/gha/build-and-sign-android.sh"
IOS_POST_CLONE = REPO_ROOT / "ios/ci_scripts/ci_post_clone.sh"
GRADLE = REPO_ROOT / "android/app/build.gradle.kts"


def _git(*args, cwd):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=True)


def _make_origin(path: Path, commits: int) -> None:
    path.mkdir(parents=True, exist_ok=True)
    _git("init", "-q", "-b", "main", cwd=path)
    _git("config", "user.email", "t@example.invalid", cwd=path)
    _git("config", "user.name", "t", cwd=path)
    for n in range(commits):
        (path / "f.txt").write_text(str(n), encoding="utf-8")
        _git("add", "f.txt", cwd=path)
        _git("commit", "-q", "-m", f"c{n}", cwd=path)


def _height_step_script() -> str:
    """The `run:` body of the workflow's Calculate git height step, dedented."""
    text = PLAY_WORKFLOW.read_text(encoding="utf-8")
    marker = "      - name: Calculate git height\n"
    start = text.index(marker)
    body = text[text.index("run: |\n", start) + len("run: |\n") :]
    lines = []
    for line in body.split("\n"):
        if line.strip() and not line.startswith("          "):
            break
        lines.append(line[10:] if line.startswith("          ") else line)
    return "\n".join(lines)


class SilentTruncationPremiseTest(unittest.TestCase):
    def test_a_shallow_clone_truncates_silently(self) -> None:
        """Why the guard checks shallowness and not emptiness.

        A shallow clone yields a SMALLER, PLAUSIBLE count with exit 0. Nothing
        about the value says it is wrong, which is why an emptiness check is not
        a guard at all.
        """
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            origin = root / "origin"
            _make_origin(origin, commits=6)
            shallow = root / "shallow"
            _git("clone", "-q", "--depth", "1", f"file://{origin}", str(shallow), cwd=root)

            full_count = _git("rev-list", "--count", "HEAD", cwd=origin).stdout.strip()
            shallow_run = subprocess.run(
                ["git", "rev-list", "--count", "HEAD"],
                cwd=shallow, capture_output=True, text=True,
            )

            self.assertEqual(shallow_run.returncode, 0, "shallow count did not even fail")
            self.assertEqual(shallow_run.stdout.strip(), "1")
            self.assertEqual(full_count, "6")
            self.assertEqual(
                _git("rev-parse", "--is-shallow-repository", cwd=shallow).stdout.strip(),
                "true",
            )


class AndroidGuardBehaviourTest(unittest.TestCase):
    """Execute the workflow's own height step. Deleting its guard turns these red."""

    def _run_step(self, cwd: Path, env_file: Path) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["bash", "-c", _height_step_script()],
            cwd=cwd,
            capture_output=True,
            text=True,
            env={"PATH": "/usr/bin:/bin:/usr/local/bin", "GITHUB_ENV": str(env_file)},
        )

    def test_it_refuses_a_shallow_clone(self) -> None:
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            origin = root / "origin"
            _make_origin(origin, commits=6)
            shallow = root / "shallow"
            _git("clone", "-q", "--depth", "1", f"file://{origin}", str(shallow), cwd=root)

            result = self._run_step(shallow, root / "env")
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("shallow", (result.stdout + result.stderr).lower())

    def test_it_accepts_a_full_clone_and_exports_the_height(self) -> None:
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            origin = root / "origin"
            _make_origin(origin, commits=6)
            full = root / "full"
            _git("clone", "-q", f"file://{origin}", str(full), cwd=root)

            env_file = root / "env"
            env_file.touch()
            result = self._run_step(full, env_file)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("BEID_GIT_HEIGHT=6", env_file.read_text(encoding="utf-8"))


class AndroidWiringTest(unittest.TestCase):
    def test_the_checkout_is_not_shallow(self) -> None:
        """The guard above can only pass if the checkout actually fetches history."""
        text = PLAY_WORKFLOW.read_text(encoding="utf-8")
        checkout = text[text.index("- uses: actions/checkout@v4") :][:200]
        self.assertIn("fetch-depth: 0", checkout)

    def test_the_height_reaches_gradle(self) -> None:
        self.assertIn("-PgitHeight=", SIGN_SCRIPT.read_text(encoding="utf-8"))

    def test_ci_refuses_to_deliver_without_a_height(self) -> None:
        """A delivered build that calls itself "local" is worse than a red one."""
        body = SIGN_SCRIPT.read_text(encoding="utf-8")
        self.assertIn("BEID_GIT_HEIGHT", body)
        self.assertRegex(body, r'elif \[\[ -n "\$\{CI:-\}" \]\]; then\s*\n\s*fail ')

    def test_gradle_defaults_to_local_and_never_to_zero_or_empty(self) -> None:
        body = GRADLE.read_text(encoding="utf-8")
        self.assertIn('buildConfigField("String", "GIT_HEIGHT"', body)
        self.assertIn('?: "local"', body)
        self.assertIn("takeIf { it.isNotBlank() }", body)

    def test_the_store_number_is_untouched(self) -> None:
        """versionCode and the build position are different numbers."""
        self.assertIn("versionCode = 1\n", GRADLE.read_text(encoding="utf-8"))


class IosWiringTest(unittest.TestCase):
    def test_the_post_clone_refuses_a_still_shallow_repository(self) -> None:
        body = IOS_POST_CLONE.read_text(encoding="utf-8")
        self.assertIn("rev-parse --is-shallow-repository", body)
        self.assertRegex(body, r"is-shallow-repository\)\" != \"false\" \]\]; then")

    def test_the_post_clone_writes_the_plist_key(self) -> None:
        body = IOS_POST_CLONE.read_text(encoding="utf-8")
        self.assertIn("BeidGitHeight", body)
        self.assertIn("PlistBuddy", body)
        self.assertIn("Add :BeidGitHeight string", body)

    def test_a_missing_plist_is_a_hard_failure(self) -> None:
        """Silently skipping would ship a CI build that calls itself local."""
        body = IOS_POST_CLONE.read_text(encoding="utf-8")
        self.assertRegex(body, r'if \[\[ ! -f "\$INFO_PLIST_PATH" \]\]; then(.|\n)*?exit 1')

    def test_the_plist_key_is_written_as_a_string(self) -> None:
        """An <integer> reads back as NSNumber and the app falls through to local."""
        self.assertIn(
            "Add :BeidGitHeight string", IOS_POST_CLONE.read_text(encoding="utf-8")
        )


class HeightDefinitionParityTest(unittest.TestCase):
    """Both lanes must compute the height from the SAME definition (beid#491).

    The point of the number is that an iOS build and an Android build showing
    the same height were built from the same commit. That holds only while both
    lanes ask git the same question. Nothing else in this file checks it: the
    Android step is executed, but iOS is only checked for writing the plist key,
    so one lane's definition could change to `--first-parent` (a different
    number for the same commit, see the issue's measurements: 261 vs 489 on
    `main`) and every other test here would stay green.

    The two are compared **to each other**, not to a literal spelled out here.
    A test that pinned the expected definition in its own source would go green
    again the moment someone updated the test to match a changed lane.
    """

    #: The location argument differs by lane and is not part of the definition:
    #: iOS runs from the checkout root via `-C`, the workflow runs in the
    #: workspace. Everything after `rev-list` is.
    DEFINITION = re.compile(r"rev-list\s+(?P<definition>.+?)\)")

    def _definition(self, path: Path, assignment: str) -> str:
        for line in path.read_text(encoding="utf-8").split("\n"):
            if re.search(assignment, line) and "rev-list" in line:
                match = self.DEFINITION.search(line)
                self.assertIsNotNone(match, f"unparsable height line in {path.name}: {line}")
                return " ".join(match.group("definition").split())
        self.fail(f"no executed height assignment found in {path.name}")

    def test_both_lanes_ask_git_the_same_question(self) -> None:
        ios = self._definition(IOS_POST_CLONE, r"GIT_HEIGHT\s*=")
        android = self._definition(PLAY_WORKFLOW, r"git_height\s*=")

        self.assertEqual(
            ios,
            android,
            "iOS and Android compute the git height from different definitions; "
            "two builds of the same commit would then show different numbers, "
            "which is the only thing this number exists to prevent.",
        )

    def test_the_shared_definition_counts_every_ancestor_of_the_built_commit(self) -> None:
        """`--first-parent` is the near-miss: same shape, different number.

        Recorded because it is the plausible edit. It is a pure function of the
        commit too, so it would look correct, but it changes meaning whenever
        history is merged differently.
        """
        ios = self._definition(IOS_POST_CLONE, r"GIT_HEIGHT\s*=")

        self.assertEqual(ios, "--count HEAD")


if __name__ == "__main__":
    unittest.main()
