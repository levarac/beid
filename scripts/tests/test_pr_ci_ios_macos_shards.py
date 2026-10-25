"""Build handoff, deterministic partition and cross-job evidence contracts."""
import importlib
import itertools
import json
import plistlib
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

from scripts.tests.test_ios_ui_smoke import tree, ONE, TWO

ROOT = Path(__file__).parents[2]


class IosShardTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue((ROOT / 'scripts/ios_test_shards.py').is_file(),
                        'parallel iOS planning and aggregate implementation is missing')
        self.tool = importlib.import_module('scripts.ios_test_shards')
        (ROOT / 'build').mkdir(exist_ok=True)

    def test_largest_first_balances_measured_durations_deterministically(self):
        tests = [f'BeidUITests/Flow/test{i}' for i in range(6)]
        durations = dict(zip(tests, [8, 7, 6, 5, 4, 2]))
        expected = self.tool.split_tests(tests, durations, 2, 3)
        for ordered in (tests[::-1], tests[2:] + tests[:2]):
            self.assertEqual(self.tool.split_tests(ordered, durations, 2, 3), expected)
        totals = [sum(durations[t] for t in shard) for shard in expected]
        self.assertLessEqual(max(totals) - min(totals), 2)
        self.tool.validate_partition(tests, expected)

    def test_unknown_tests_go_to_lighter_shard_and_are_never_lost(self):
        shards = self.tool.split_tests([ONE, TWO], {ONE: 10}, 2, 3)
        self.assertEqual(shards, [[ONE], [TWO]])
        self.assertEqual(self.tool.split_tests([ONE, TWO], {}, 1, 3), [[ONE, TWO]])

    def test_duplicate_missing_extra_empty_and_invalid_partitions_fail(self):
        for tests, shards in (([ONE, TWO], [[ONE], []]), ([ONE], [[ONE], [ONE]]),
                              ([ONE], [[ONE, TWO]]), ([ONE, ONE], [[ONE]]), ([], [[]])):
            with self.subTest(tests=tests, shards=shards), self.assertRaises(ValueError):
                self.tool.validate_partition(tests, shards)
        with self.assertRaises(ValueError):
            self.tool.split_tests([ONE, ONE], {}, 2, 3)

    def test_duration_data_rejects_duplicates_nonfinite_and_nonpositive(self):
        self.assertEqual(self.tool.parse_durations(f'# source run 42\n{ONE}\t2.5\n'), {ONE: 2.5})
        for text in (f'{ONE}\t2\n{ONE}\t3', f'{ONE}\tnan', f'{ONE}\t-1',
                     f'{ONE}\t0', 'bad\t2'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.tool.parse_durations(text)

    def test_flat_build_enumeration_is_authoritative(self):
        self.assertEqual(self.tool.parse_enumeration(f'{ONE}()\n{TWO}()\n'), [ONE, TWO])
        for text in ('', f'{ONE}\n{ONE}\n', 'BeidUITests/Flow/testOne bad'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.tool.parse_enumeration(text)

    def test_plan_smoke_uses_one_shard_and_full_uses_two(self):
        for mode, count in (('smoke', 1), ('full', 2)):
            plan = self.tool.make_plan(mode, [ONE, TWO], [ONE], {ONE: 2, TWO: 3}, 3)
            self.assertEqual(len(plan['shards']), count)
            self.assertEqual(plan['full_tests'], [ONE, TWO])
            self.tool.validate_partition([ONE] if mode == 'smoke' else [ONE, TWO], plan['shards'])
        with self.assertRaises(ValueError):
            self.tool.make_plan('smoke', [ONE], [TWO], {}, 3)

    def test_aggregate_trusts_only_successful_classifier_for_skip(self):
        base = {'changes': {'result': 'success', 'outputs': {'ios': 'false', 'error': 'false'}}}
        self.assertFalse(self.tool.lane_needed('pull_request', base))
        for event in ('push', 'merge_group', 'schedule', 'workflow_dispatch'):
            self.assertTrue(self.tool.lane_needed(event, base))
        for result in ('failure', 'skipped', 'cancelled'):
            self.assertTrue(self.tool.lane_needed('pull_request', {
                'changes': {'result': result, 'outputs': {'ios': 'false'}}}))
        for outputs in ({}, {'ios': ''}, {'ios': 'false', 'error': 'true'}):
            self.assertTrue(self.tool.lane_needed('pull_request', {
                'changes': {'result': 'success', 'outputs': outputs}}))

    def test_every_needed_job_must_succeed_including_missing_results(self):
        needs = {job: {'result': 'success'} for job in ('ios-build', 'ios-unit', 'ios-ui')}
        self.tool.require_success(needs)
        for job, result in itertools.product(needs, ('failure', 'skipped', 'cancelled', '')):
            changed = {**needs, job: {'result': result}}
            with self.subTest(job=job, result=result), self.assertRaises(ValueError):
                self.tool.require_success(changed)
        with self.assertRaises(ValueError):
            self.tool.require_success({})

    def test_union_requires_every_built_ui_case_and_rejects_duplicates_and_skips(self):
        plan = self.tool.make_plan('full', [ONE, TWO], [ONE], {}, 3)
        unit_tree = tree()['testNodes'][0]['children'][0]
        ui_tree = tree(unit=False)
        ui_children = ui_tree['testNodes'][0]['children'][0]['children'][0]['children']
        reports = [self.tool.make_report('unit', 'full', 'BeidTests', {'testNodes': [unit_tree]}, 1)]
        for i, case in enumerate(ui_children, 1):
            part = tree(ui=[case], unit=False)
            reports.append(self.tool.make_report(f'ui-{i}', 'full', 'BeidUITests', part, 1))
        self.tool.verify_reports(plan, reports)
        for bad in (reports[:-1], reports + [reports[-1]],
                    [{**r, 'mode': 'smoke'} for r in reports]):
            with self.assertRaises(ValueError):
                self.tool.verify_reports(plan, bad)
        ui_children[0]['result'] = 'Skipped'
        with self.assertRaises(ValueError):
            self.tool.make_report('ui-1', 'full', 'BeidUITests', tree(ui=[ui_children[0]], unit=False), 1)

    def test_summary_counts_are_structured_consistent_and_nonzero(self):
        summary = dict(result='Passed', totalTestCount=1, passedTests=1, failedTests=0,
                       skippedTests=0, expectedFailures=0)
        self.tool.validate_summary(summary)
        for changed in ({'totalTestCount': 0}, {'passedTests': True}, {'failedTests': 1},
                        {'result': 'Failed'}, {'skippedTests': -1}):
            with self.assertRaises(ValueError):
                self.tool.validate_summary({**summary, **changed})

    def run_rerun_aggregate(self, root, mode, unit_attempt, latest_results=None,
                            missing_job=None, wrong_plan=False):
        plan = self.tool.make_plan(mode, [ONE, TWO], [ONE], {}, 3)
        (root / 'plan').mkdir()
        (root / 'plan/plan.json').write_text(json.dumps(plan))
        needs = {job: {'result': 'success'} for job in ('ios-build', 'ios-unit', 'ios-ui')}
        needs['ios-build']['outputs'] = {'mode': mode}
        for job, result in (latest_results or {}).items():
            needs[job]['result'] = result
        (root / 'needs.json').write_text(json.dumps(needs))
        unit = {'testNodes': [tree()['testNodes'][0]['children'][0]]}
        ui_cases = tree(unit=False)['testNodes'][0]['children'][0]['children'][0]['children']
        entries = [('unit', 'BeidTests', unit, unit_attempt)]
        for i, shard in enumerate(plan['shards'], 1):
            cases = [case for case in ui_cases
                     if f"BeidUITests/{case['nodeIdentifier'].removesuffix('()')}" in shard]
            entries.append((f'ui-{i}', 'BeidUITests', tree(ui=cases, unit=False), 1))
        for job, bundle, payload, attempt in entries:
            if job == missing_job:
                continue
            report = self.tool.make_report(job, mode, bundle, payload, attempt)
            folder = root / 'evidence' / f'ios-evidence-{job}'
            folder.mkdir(parents=True)
            (folder / 'report.json').write_text(json.dumps(report))
        if wrong_plan:
            # The evidence is passing, but it belongs to a different assignment.
            plan['shards'].reverse()
            (root / 'plan/plan.json').write_text(json.dumps(plan))
        summary = root / 'summary.md'
        with patch('sys.argv', ['ios_test_shards', 'aggregate', '--event', 'pull_request',
                                '--mode', mode, '--needs', str(root / 'needs.json'),
                                '--root', str(root), '--summary', str(summary)]):
            code = self.tool.main()
        return code, summary.read_text()

    def test_partial_rerun_reuses_first_attempt_plan_and_ui_evidence(self):
        for mode in ('smoke', 'full'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory(dir=ROOT / 'build') as temp:
                code, summary = self.run_rerun_aggregate(Path(temp), mode, unit_attempt=2)
                self.assertEqual(code, 0, summary)
                self.assertIn('| Job | Attempt | Bundle |', summary)
                self.assertIn('| unit | 2 | BeidTests |', summary)
                self.assertIn('| ui-1 | 1 | BeidUITests |', summary)

    def test_latest_failed_job_rejects_older_successful_evidence(self):
        for job, attempt in itertools.product(('ios-build', 'ios-unit', 'ios-ui'), (1, 2)):
            with self.subTest(job=job, attempt=attempt), tempfile.TemporaryDirectory(dir=ROOT / 'build') as temp:
                code, summary = self.run_rerun_aggregate(
                    Path(temp), 'full', unit_attempt=attempt, latest_results={job: 'failure'})
                self.assertEqual(code, 1)
                self.assertIn(f'| {job} | failure |', summary)
                self.assertIn('Evidence verification failed', summary)

    def test_partial_rerun_success_requires_evidence_matching_plan(self):
        for missing_job, wrong_plan in (('unit', False), ('ui-1', False), (None, True)):
            with self.subTest(missing=missing_job, mismatch=wrong_plan), tempfile.TemporaryDirectory(dir=ROOT / 'build') as temp:
                code, summary = self.run_rerun_aggregate(
                    Path(temp), 'full', unit_attempt=2, missing_job=missing_job, wrong_plan=wrong_plan)
                self.assertEqual(code, 1)
                self.assertIn('Evidence verification failed', summary)

    def test_pack_preserves_executable_and_symlinks_excludes_intermediates(self):
        with tempfile.TemporaryDirectory(dir=ROOT / 'build') as temp:
            root = Path(temp)
            products = root / 'DerivedData/Build/Products'
            products.mkdir(parents=True)
            app = products / 'Debug-iphonesimulator/Beid.app'
            app.mkdir(parents=True)
            binary = app / 'Beid'
            binary.write_bytes(b'payload')
            binary.chmod(0o755)
            (app / 'link').symlink_to('Beid')
            (products / 'Beid.xctestrun').write_bytes(plistlib.dumps({
                'BeidTests': {'TestHostPath': '__TESTROOT__/Debug-iphonesimulator/Beid.app'}}))
            extra = root / 'DerivedData/Build/Intermediates.noindex'
            extra.mkdir()
            (extra / 'big').write_bytes(b'not needed')
            archive = root / 'products.tar.gz'
            size = self.tool.pack_products(products, archive)
            self.assertEqual(size, archive.stat().st_size)
            with tarfile.open(archive) as tar:
                names = tar.getnames()
                self.assertFalse(any('Intermediates' in n for n in names))
                self.assertTrue(tar.getmember('Products/Debug-iphonesimulator/Beid.app/link').issym())
                self.assertEqual(tar.getmember('Products/Debug-iphonesimulator/Beid.app/Beid').mode & 0o111, 0o111)

    def test_aggregate_cli_summarizes_failures_and_only_classifier_can_bypass(self):
        import subprocess
        import sys
        with tempfile.TemporaryDirectory(dir=ROOT / 'build') as temp:
            root = Path(temp)
            needs = root / 'needs.json'
            summary = root / 'summary.md'
            command = [sys.executable, '-m', 'scripts.ios_test_shards', 'aggregate',
                       '--event', 'pull_request', '--mode', '', '--needs', str(needs),
                       '--root', str(root), '--summary', str(summary)]
            needs.write_text(json.dumps({'changes': {'result': 'success', 'outputs': {'ios': 'false'}}}))
            result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('not needed', summary.read_text())
            needs.write_text(json.dumps({'changes': {'result': 'failure'},
                                         'ios-build': {'result': 'cancelled'}}))
            summary.write_text('')
            result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('ios-build', summary.read_text())
            self.assertIn('cancelled', summary.read_text())

    def test_test_job_shell_selects_exact_bundle_or_shard_and_retains_child_exit(self):
        import os
        import subprocess
        import sys
        import textwrap
        from scripts.tests.test_pr_ci_lane_skip import job_block, IOS
        from scripts.tests.test_pr_ci_ios_macos_workflow import step_block
        with tempfile.TemporaryDirectory(dir=ROOT / 'build') as temp:
            root = Path(temp)
            (root / 'Products').mkdir()
            (root / 'Products/Beid.xctestrun').touch()
            (root / 'plan').mkdir()
            (root / 'plan/ui-2.txt').write_text(TWO + '\n')
            fake = root / 'xcodebuild'
            fake.write_text(f'#!{sys.executable}\nimport json, os, sys\n'
                            'print(json.dumps(sys.argv[1:]))\n'
                            "sys.exit(int(os.environ['CHILD_EXIT']))\n")
            fake.chmod(0o755)
            for job, mode, code in itertools.product(('unit', 'ui'), ('smoke', 'full'), (0, 65)):
                block = step_block(job_block(IOS, 'ios-' + job), 'Test without rebuilding')
                script = textwrap.dedent(block.split('        run: |\n', 1)[1])
                result = subprocess.run(['bash', '-c', script], capture_output=True, text=True,
                    env={**os.environ, 'PATH': str(root) + os.pathsep + os.environ['PATH'],
                         'CI_OUTPUT_ROOT': str(root), 'SIMULATOR_UDID': 'owned', 'UI_SHARD': '2',
                         'TEST_MODE': mode, 'CHILD_EXIT': str(code)})
                self.assertEqual(result.returncode, code, result.stderr)
                argv = json.loads(result.stdout)
                self.assertEqual([a for a in argv if a.startswith('-only-testing:')],
                                 ['-only-testing:BeidTests' if job == 'unit' else '-only-testing:' + TWO])
                self.assertNotIn('-project', argv)
                self.assertNotIn('-derivedDataPath', argv)
                self.assertEqual(argv[argv.index('-parallel-testing-enabled') + 1], 'NO')
                self.assertEqual(argv[argv.index('-resultBundlePath') + 1], str(root / 'Tests.xcresult'))

    def test_unit_report_keeps_existing_expected_failure_accounting(self):
        import subprocess
        import sys
        with tempfile.TemporaryDirectory(dir=ROOT / 'build') as temp:
            root = Path(temp)
            unit = tree()['testNodes'][0]['children'][0]
            unit['children'][0]['result'] = 'Expected Failure'
            (root / 'test-tree.json').write_text(json.dumps({'testNodes': [unit]}))
            (root / 'test-summary.json').write_text(json.dumps(dict(
                result='Passed', totalTestCount=1, passedTests=0, failedTests=0,
                skippedTests=0, expectedFailures=1)))
            result = subprocess.run([sys.executable, '-m', 'scripts.ios_test_shards', 'report',
                '--mode', 'full', '--bundle', 'BeidTests', '--job', 'unit', '--run-attempt', '2',
                '--root', str(root), '--summary', str(root / 'summary.md')],
                cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads((root / 'report.json').read_text())['skipped'], 1)
            self.assertEqual(json.loads((root / 'report.json').read_text())['run_attempt'], 2)
            self.assertIn('| unit | 2 | BeidTests |', (root / 'summary.md').read_text())
