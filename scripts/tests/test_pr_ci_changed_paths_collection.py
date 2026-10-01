"""The changed-path collection step is pinned to the event's SHAs and fails closed.

pr-ci.yml, pr-ci-ios-macos.yml and pr-ci-lab-cli.yml share one collection step.
Its github-script body is extracted from each workflow and run under node with a
fake `github`, `context` and `core`, so the tests exercise the shipped script.
"""

import json
import os
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

from scripts.ci_change_filter import classify

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github/workflows"
NAMES = ("pr-ci.yml", "pr-ci-ios-macos.yml", "pr-ci-lab-cli.yml")

HARNESS = r"""
const fs = require('fs');
const scenario = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const script = fs.readFileSync(process.argv[3], 'utf8');
const calls = [];
const github = {
  // Only the compare endpoint exists: any other call (for example the pull
  // request's current file list) throws and shows up as a collection error.
  rest: { repos: { compareCommitsWithBasehead: 'COMPARE' } },
  paginate: async (endpoint, params, mapper) => {
    if (endpoint !== 'COMPARE') throw new Error('unexpected endpoint');
    calls.push(params);
    if (scenario.apiError) throw new Error(scenario.apiError);
    return scenario.pages.flatMap(files => mapper({ data: { files } }));
  },
};
const warnings = [];
const core = { warning: message => warnings.push(message) };
const context = scenario.context;
context.repo = { owner: 'levarac', repo: 'beid' };
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
new AsyncFunction('github', 'context', 'core', 'require', 'process', script)(
  github, context, core, require, process,
).then(() => {
  console.log(JSON.stringify({ calls, warnings, output: JSON.parse(fs.readFileSync(process.env.RUNNER_TEMP + '/beid-changed-files.json', 'utf8')) }));
});
"""


def collection_script(name: str) -> str:
    text = (WORKFLOWS / name).read_text(encoding="utf-8")
    match = re.search(
        r"      - name: Collect changed paths\n        uses: actions/github-script@[^\n]+\n"
        r"        with:\n          script: \|\n(.*?)\n\n      - name:",
        text,
        re.S,
    )
    assert match, name
    return textwrap.dedent(match.group(1))


def entries(count: int, prefix: str = "docs/f") -> list:
    return [{"filename": f"{prefix}{i}.md"} for i in range(count)]


def pull_request(base: str, head: str, **extra) -> dict:
    # `issue.number` and any "current" PR state deliberately differ between runs
    # of the same event: the result must not depend on them.
    return {
        "eventName": "pull_request",
        "payload": {"pull_request": {"base": {"sha": base}, "head": {"sha": head}}},
        "issue": {"number": 726},
        **extra,
    }


@unittest.skipUnless(shutil.which("node"), "node is required to run the github-script body")
class CollectionStepTest(unittest.TestCase):
    def run_script(self, name: str, scenario: dict) -> dict:
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            (folder / "harness.js").write_text(HARNESS, encoding="utf-8")
            (folder / "scenario.json").write_text(json.dumps(scenario), encoding="utf-8")
            (folder / "script.js").write_text(collection_script(name), encoding="utf-8")
            result = subprocess.run(
                ["node", "harness.js", "scenario.json", "script.js"],
                cwd=folder, capture_output=True, text=True,
                env={"PATH": os.environ["PATH"], "RUNNER_TEMP": str(folder)},
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)

    def test_the_three_workflows_share_one_collection_script(self):
        scripts = {name: collection_script(name) for name in NAMES}
        self.assertEqual(len(set(scripts.values())), 1, "collection scripts have diverged")

    def test_pull_request_is_classified_from_the_events_own_base_and_head(self):
        for name in NAMES:
            with self.subTest(workflow=name):
                result = self.run_script(name, {
                    "context": pull_request("b" * 40, "a" * 40),
                    "pages": [entries(2)],
                })
                self.assertEqual(result["calls"][0]["basehead"], f"{'b' * 40}...{'a' * 40}")
                self.assertNotIn("pull_number", result["calls"][0])
                self.assertEqual(result["output"], {"files": ["docs/f0.md", "docs/f1.md"]})

    def test_a_rerun_depends_only_on_the_events_shas(self):
        # Two runs of the same event, as a re-run of an older run would be: the
        # pull request has since moved on (different issue number and unrelated
        # state), but the payload SHAs are the same. The calls must be identical.
        original = pull_request("b" * 40, "a" * 40)
        later = pull_request("b" * 40, "a" * 40, issue={"number": 999}, extra="newer head")
        for name in NAMES:
            with self.subTest(workflow=name):
                first = self.run_script(name, {"context": original, "pages": [entries(1)]})
                second = self.run_script(name, {"context": later, "pages": [entries(1)]})
                self.assertEqual(first["calls"], second["calls"])
                self.assertEqual(first["output"], second["output"])

    def test_a_different_head_sha_is_a_different_query(self):
        first = self.run_script("pr-ci.yml", {"context": pull_request("b" * 40, "a" * 40), "pages": [[]]})
        second = self.run_script("pr-ci.yml", {"context": pull_request("b" * 40, "c" * 40), "pages": [[]]})
        self.assertNotEqual(first["calls"], second["calls"])

    def test_a_reverted_code_change_is_not_hidden_by_a_docs_only_head(self):
        # The pinned diff for the older head still contains the code change, so
        # the classifier does not call it documentation-only.
        result = self.run_script("pr-ci-ios-macos.yml", {
            "context": pull_request("b" * 40, "a" * 40),
            "pages": [[{"filename": "docs/a.md"}, {"filename": "ios/Beid/App.swift"}]],
        })
        outputs = classify(result["output"]["files"])
        self.assertTrue(outputs["lint"])

    def test_renames_contribute_both_paths(self):
        result = self.run_script("pr-ci.yml", {
            "context": pull_request("b" * 40, "a" * 40),
            "pages": [[{"filename": "docs/new.md", "previous_filename": "ios/Old.swift"}]],
        })
        self.assertEqual(result["output"]["files"], ["docs/new.md", "ios/Old.swift"])

    def test_push_uses_before_and_after(self):
        result = self.run_script("pr-ci.yml", {
            "context": {"eventName": "push", "payload": {"before": "1" * 40, "after": "2" * 40}},
            "pages": [entries(1)],
        })
        self.assertEqual(result["calls"][0]["basehead"], f"{'1' * 40}...{'2' * 40}")
        self.assertEqual(result["output"], {"files": ["docs/f0.md"]})

    def test_unbounded_events_fail_closed(self):
        for context in (
            {"eventName": "push", "payload": {"before": "0" * 40, "after": "2" * 40}},
            {"eventName": "workflow_dispatch", "payload": {}},
        ):
            with self.subTest(event=context["eventName"]):
                result = self.run_script("pr-ci.yml", {"context": context, "pages": []})
                self.assertIn("error", result["output"])
                self.assertEqual(classify([])["error"], True)

    def test_a_list_that_reaches_the_cap_is_treated_as_truncated(self):
        for name in NAMES:
            with self.subTest(workflow=name):
                # 300 is the compare API's file cap: a full list may hide more.
                result = self.run_script(name, {
                    "context": pull_request("b" * 40, "a" * 40),
                    "pages": [entries(100, "a"), entries(100, "b"), entries(100, "c")],
                })
                self.assertIn("error", result["output"])
                self.assertNotIn("files", result["output"])
                self.assertIn("truncated", result["output"]["error"])

    def test_a_list_just_under_the_cap_is_used(self):
        result = self.run_script("pr-ci.yml", {
            "context": pull_request("b" * 40, "a" * 40),
            "pages": [entries(100, "a"), entries(100, "b"), entries(99, "c")],
        })
        self.assertEqual(len(result["output"]["files"]), 299)

    def test_renames_do_not_inflate_the_truncation_count(self):
        pages = [[{"filename": f"docs/n{i}.md", "previous_filename": f"docs/o{i}.md"} for i in range(150)]]
        result = self.run_script("pr-ci.yml", {"context": pull_request("b" * 40, "a" * 40), "pages": pages})
        self.assertEqual(len(result["output"]["files"]), 300)

    def test_an_api_failure_fails_closed(self):
        for name in NAMES:
            with self.subTest(workflow=name):
                result = self.run_script(name, {
                    "context": pull_request("b" * 40, "a" * 40),
                    "apiError": "boom", "pages": [],
                })
                self.assertIn("error", result["output"])
                self.assertEqual(len(result["warnings"]), 1)

    def test_the_error_marker_makes_the_classifier_fail_closed(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "files.json"
            source.write_text(json.dumps({"error": "file list may be truncated"}), encoding="utf-8")
            out = subprocess.run(
                ["python3", "scripts/ci_change_filter.py", "--input", str(source)],
                cwd=ROOT, capture_output=True, text=True, check=True,
            ).stdout
        self.assertIn("error=true", out)


if __name__ == "__main__":
    unittest.main()
