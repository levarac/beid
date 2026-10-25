#!/usr/bin/env python3
"""Plan isolated iOS jobs and verify the union of their executed evidence."""
from __future__ import annotations

import argparse
from collections import Counter
import json
import math
from pathlib import Path
import plistlib
import re
import sys
import tarfile

from scripts.ios_ui_smoke import (
    case_duration, parse_smoke_list, validate_results,
)
from scripts.run_local_tests import parse_xcresult_tests

# Unknown UI cases retain the original bundle-mean estimate. Unit estimates
# use the measured bundle mean; neither fallback claims a per-case measurement.
FALLBACK_SECONDS = 1412.663 / 66
UNIT_FALLBACK_SECONDS = 763.6182074546814 / 898
IDENTIFIER = re.compile(r'Beid(?:UI)?Tests/[A-Za-z_]\w*/test\w+')


def parse_durations(text):
    durations = {}
    for line in text.splitlines():
        line = line.partition('#')[0].strip()
        if not line:
            continue
        fields = line.split('\t')
        if len(fields) != 2 or not IDENTIFIER.fullmatch(fields[0]):
            raise ValueError(f'invalid duration row: {line!r}')
        test, raw = fields
        seconds = float(raw)
        if test in durations or not math.isfinite(seconds) or seconds <= 0:
            raise ValueError(f'duplicate or invalid duration: {test}')
        durations[test] = seconds
    return durations


def parse_enumeration(text, bundle='BeidUITests'):
    # xcodebuild -enumerate-tests -test-enumeration-style flat -format text
    # emits identifiers usable verbatim by -only-testing. Target/class headings
    # are not methods. Reject malformed method-like lines rather than drop them.
    tests = []
    for line in text.splitlines():
        line = line.strip().removesuffix('()')
        if not line.startswith(bundle + '/'):
            continue
        if line.count('/') < 2:
            continue
        if not IDENTIFIER.fullmatch(line):
            raise ValueError(f'invalid enumerated method: {line!r}')
        tests.append(line)
    if not tests or len(tests) != len(set(tests)):
        raise ValueError('build enumeration has no cases or duplicate cases')
    return sorted(tests)


def validate_partition(tests, shards):
    if not tests or len(tests) != len(set(tests)):
        raise ValueError('expected tests are empty or duplicated')
    actual = Counter(test for shard in shards for test in shard)
    if actual != Counter(tests):
        raise ValueError('shard union differs from build enumeration or contains duplicates')


def split_tests(tests, durations, count, fallback=FALLBACK_SECONDS):
    if count < 1 or not math.isfinite(fallback) or fallback <= 0:
        raise ValueError('invalid shard count or fallback duration')
    if not tests or len(tests) != len(set(tests)):
        raise ValueError('empty or duplicate test list')
    shards, totals = [[] for _ in range(count)], [0.0] * count
    # Longest measured cases first, stable identifier tie break; unknown cases
    # follow measured cases and are assigned to the then-lightest shard.
    ordered = sorted(tests, key=lambda t: (t not in durations, -durations.get(t, 0), t))
    for test in ordered:
        slot = min(range(count), key=lambda i: (totals[i], i))
        shards[slot].append(test)
        totals[slot] += durations.get(test, fallback)
    shards = [sorted(shard) for shard in shards]
    validate_partition(tests, shards)
    if any(not shard for shard in shards):
        raise ValueError('empty test shard')
    return shards


def make_unit_plan(tests, durations):
    # Class selection avoids method-selection quirks and keeps shared stubs in
    # ReportSubmissionOperatorIntegrationTests within one process/simulator.
    validate_partition(tests, [tests])
    classes = {}
    for test in sorted(tests):
        if not test.startswith('BeidTests/') or not IDENTIFIER.fullmatch(test):
            raise ValueError('invalid unit method')
        classes.setdefault(test.rsplit('/', 1)[0], []).append(test)
    weights = {name: sum(durations.get(t, UNIT_FALLBACK_SECONDS) for t in methods)
               for name, methods in classes.items()}
    selectors = split_tests(list(classes), weights, 2)
    shards = [sorted(t for name in shard for t in classes[name]) for shard in selectors]
    validate_partition(tests, shards)
    return dict(granularity='class', full_tests=sorted(tests), shards=shards, selectors=selectors,
                estimated_seconds=[sum(weights[name] for name in shard) for shard in selectors],
                unmeasured=sorted(set(tests) - durations.keys()))


def validate_unit_plan(unit):
    if unit['granularity'] != 'class' or len(unit['shards']) != 2:
        raise ValueError('unit plan must have two class-level shards')
    validate_partition(unit['full_tests'], unit['shards'])
    seen = set()
    for shard, selectors in zip(unit['shards'], unit['selectors'], strict=True):
        classes = sorted({test.rsplit('/', 1)[0] for test in shard})
        if not shard or classes != selectors or seen.intersection(classes):
            raise ValueError('unit class missing, duplicated or split across shards')
        seen.update(classes)


def make_plan(mode, full_tests, smoke, durations, fallback=FALLBACK_SECONDS,
              *, unit_tests, unit_durations):
    if mode not in ('smoke', 'full') or not set(smoke) <= set(full_tests):
        raise ValueError('invalid mode or smoke list missing from build')
    selected = smoke if mode == 'smoke' else full_tests
    shards = split_tests(selected, durations, 1 if mode == 'smoke' else 2, fallback)
    validate_partition(full_tests, [full_tests])
    return dict(unit=make_unit_plan(unit_tests, unit_durations), mode=mode, full_tests=sorted(full_tests), smoke=smoke, shards=shards,
                estimated_seconds=[sum(durations.get(t, fallback) for t in s) for s in shards],
                unmeasured=sorted(set(selected) - durations.keys()))


def lane_needed(event, needs):
    changes = needs.get('changes', {})
    outputs = changes.get('outputs', {})
    return not (event == 'pull_request' and changes.get('result') == 'success'
                and outputs.get('ios') == 'false' and outputs.get('error') != 'true')


def require_success(needs):
    for job in ('ios-build', 'ios-unit', 'ios-ui'):
        if needs.get(job, {}).get('result') != 'success':
            raise ValueError(f'needed job did not succeed: {job}')


def validate_summary(summary):
    keys = ('totalTestCount', 'passedTests', 'failedTests', 'skippedTests', 'expectedFailures')
    values = [summary[k] for k in keys]
    if any(type(v) is not int or v < 0 for v in values):
        raise ValueError('summary counts must be nonnegative integers')
    if values[0] <= 0 or sum(values[1:]) != values[0]:
        raise ValueError('summary counts are empty or inconsistent')
    if summary['result'] != 'Passed' or summary['failedTests'] != 0:
        raise ValueError('structured test summary did not pass')


def make_report(job, mode, bundle, payload, run_attempt):
    if mode not in ('smoke', 'full'):
        raise ValueError('invalid mode in report')
    if type(run_attempt) is not int or run_attempt < 1:
        raise ValueError('run attempt must be a positive integer')
    counts = parse_xcresult_tests(payload)
    if set(counts.bundles) != {bundle} or counts.bundles[bundle].total <= 0 or counts.warnings:
        raise ValueError('unexpected, empty or malformed test bundle')
    duration = 0.0
    cases = []

    def walk(node, suite=None):
        nonlocal duration
        if isinstance(node, list):
            for child in node:
                walk(child, suite)
        elif isinstance(node, dict):
            kind = str(node.get('nodeType', node.get('type', ''))).lower()
            if kind == 'test suite':
                suite = str(node.get('name', '')).removeprefix(bundle + '.')
            if kind == 'test case':
                duration += case_duration(node)
                identifier = str(node.get('nodeIdentifier') or f"{suite}/{node.get('name', '')}").removesuffix('()')
                if not identifier.startswith(bundle + '/'):
                    identifier = bundle + '/' + identifier
                cases.append(dict(identifier=identifier, result=node.get('result', node.get('testStatus')),
                                  seconds=case_duration(node)))
            for key in ('children', 'testNodes', 'subtests'):
                if key in node:
                    walk(node[key], suite)
    walk(payload)
    c = counts.bundles[bundle]
    if len(cases) != c.total or c.failed or c.passed + c.skipped != c.total:
        raise ValueError('test tree counts are inconsistent or failing')
    if bundle == 'BeidUITests' and any(c['result'] != 'Passed' for c in cases):
        raise ValueError('UI skips and nonpassing cases fail verification')
    return dict(job=job, run_attempt=run_attempt, mode=mode, bundle=bundle, total=c.total, passed=c.passed,
                failed=c.failed, skipped=c.skipped, seconds=duration, cases=cases, tree=payload)


def verify_reports(plan, reports):
    validate_unit_plan(plan['unit'])
    expected_jobs = {'unit-1', 'unit-2', *(f'ui-{i}' for i in range(1, len(plan['shards']) + 1))}
    if Counter(r['job'] for r in reports) != Counter(expected_jobs):
        raise ValueError('missing, duplicate or unexpected job evidence')
    validate_partition(plan['smoke'] if plan['mode'] == 'smoke' else plan['full_tests'], plan['shards'])
    combined = []
    for report in reports:
        job = report['job']
        bundle = 'BeidTests' if job.startswith('unit-') else 'BeidUITests'
        if report['mode'] != plan['mode'] or report['bundle'] != bundle:
            raise ValueError('job mode or bundle mismatch')
        # Recompute from the raw tree: reports cannot claim better counts.
        if make_report(job, plan['mode'], bundle, report['tree'], report['run_attempt']) != report:
            raise ValueError('report differs from raw test evidence')
        shards = plan['unit']['shards'] if bundle == 'BeidTests' else plan['shards']
        shard = shards[int(job.split('-')[1]) - 1]
        if Counter(c['identifier'] for c in report['cases']) != Counter(shard):
            raise ValueError('executed cases differ from assigned shard')
        combined.append(report['tree'])
    # Retain the previous exact smoke comparison and full listed-test check,
    # now across all jobs; full additionally requires every discovered case.
    validate_results(plan['mode'], plan['smoke'], combined)


def summary_table(mode, reports):
    lines = [f'\nMode: **{mode}**. Durations sum Test Case nodes, excluding suite totals.\n',
             '| Job | Attempt | Bundle | Cases | Passed | Failed | Skipped | Duration (s) |',
             '| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: |']
    for r in sorted(reports, key=lambda r: r['job']):
        lines.append(f"| {r['job']} | {r['run_attempt']} | {r['bundle']} | {r['total']} | {r['passed']} | {r['failed']} | {r['skipped']} | {r['seconds']:.3f} |")
    return '\n'.join(lines) + '\n'


def pack_products(products, archive):
    runs = list(products.glob('*.xctestrun'))
    if len(runs) != 1:
        raise ValueError('expected exactly one xctestrun file')
    # Xcode normally emits __TESTROOT__. Normalize any absolute Products
    # references too, so no job depends on the build runner's filesystem.
    def relocate(value):
        if isinstance(value, str):
            return value.replace(str(products.resolve()), '__TESTROOT__')
        if isinstance(value, dict):
            return {k: relocate(v) for k, v in value.items()}
        if isinstance(value, list):
            return [relocate(v) for v in value]
        return value
    data = plistlib.loads(runs[0].read_bytes())
    runs[0].write_bytes(plistlib.dumps(relocate(data)))
    for path in products.rglob('*'):
        if path.is_symlink() and not path.resolve().is_relative_to(products.resolve()):
            raise ValueError(f'nonportable Products symlink: {path.name}')
    archive.parent.mkdir(parents=True, exist_ok=True)

    def keep(info):
        # Keep app/framework/bundle executables and resources intact. dSYMs and
        # loose compiler products are unnecessary for test-without-building.
        parts = Path(info.name).parts
        if any(p.endswith(('.dSYM', '.swiftmodule')) for p in parts):
            return None
        if Path(info.name).suffix in ('.a', '.o'):
            return None
        return info
    with tarfile.open(archive, 'w:gz') as output:
        output.add(products, arcname='Products', filter=keep)
    return archive.stat().st_size


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    plan = sub.add_parser('plan')
    plan.add_argument('--mode', choices=('smoke', 'full'), required=True)
    plan.add_argument('--enumeration', type=Path, required=True)
    plan.add_argument('--unit-enumeration', type=Path, required=True)
    plan.add_argument('--unit-durations', type=Path, default=Path('ios/ci/unit-test-durations.tsv'))
    plan.add_argument('--durations', type=Path, default=Path('ios/ci/ui-test-durations.tsv'))
    plan.add_argument('--smoke', type=Path, default=Path('ios/ci/ui-smoke-tests.txt'))
    plan.add_argument('--output', type=Path, required=True)
    pack = sub.add_parser('pack')
    pack.add_argument('--products', type=Path, required=True)
    pack.add_argument('--archive', type=Path, required=True)
    report = sub.add_parser('report')
    report.add_argument('--mode', choices=('smoke', 'full'), required=True)
    report.add_argument('--bundle', choices=('BeidTests', 'BeidUITests'), required=True)
    report.add_argument('--job', required=True)
    report.add_argument('--run-attempt', type=int, required=True)
    report.add_argument('--root', type=Path, required=True)
    report.add_argument('--summary', type=Path, required=True)
    aggregate = sub.add_parser('aggregate')
    aggregate.add_argument('--event', required=True)
    aggregate.add_argument('--needs', type=Path, required=True)
    aggregate.add_argument('--root', type=Path, required=True)
    aggregate.add_argument('--mode', required=True)
    aggregate.add_argument('--summary', type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == 'plan':
            result = make_plan(args.mode, parse_enumeration(args.enumeration.read_text()),
                               parse_smoke_list(args.smoke.read_text()), parse_durations(args.durations.read_text()),
                               unit_tests=parse_enumeration(args.unit_enumeration.read_text(), 'BeidTests'),
                               unit_durations=parse_durations(args.unit_durations.read_text()))
            validate_unit_plan(result['unit'])
            args.output.mkdir(parents=True, exist_ok=True)
            (args.output / 'plan.json').write_text(json.dumps(result, indent=2) + '\n')
            for i, shard in enumerate(result['shards'], 1):
                (args.output / f'ui-{i}.txt').write_text('\n'.join(shard) + '\n')
            for i, selectors in enumerate(result['unit']['selectors'], 1):
                (args.output / f'unit-{i}.txt').write_text('\n'.join(selectors) + '\n')
            print('unit-shards=[1, 2]')
            print(json.dumps(dict(bundle='BeidTests', granularity='class',
                                  classes_per_shard=[len(s) for s in result['unit']['selectors']],
                                  cases_per_shard=[len(s) for s in result['unit']['shards']],
                                  estimated_seconds=result['unit']['estimated_seconds'],
                                  unmeasured_cases=len(result['unit']['unmeasured']))), file=sys.stderr)
            print('ui-shards=' + json.dumps(list(range(1, len(result['shards']) + 1))))
            print(json.dumps(dict(bundle='BeidUITests', mode=result['mode'], cases_per_shard=[len(s) for s in result['shards']],
                                  estimated_seconds=result['estimated_seconds'],
                                  unmeasured_cases=len(result['unmeasured']))), file=sys.stderr)
        elif args.command == 'pack':
            size = pack_products(args.products, args.archive)
            print(f'Build/Products archive: {size} bytes ({size / 1024**2:.2f} MiB)')
        elif args.command == 'report':
            summary = json.loads((args.root / 'test-summary.json').read_text())
            # Keep raw structured failure data as an artifact even when validation fails.
            validate_summary(summary)
            result = make_report(args.job, args.mode, args.bundle,
                                 json.loads((args.root / 'test-tree.json').read_text()), args.run_attempt)
            if result['total'] != summary['totalTestCount'] or any(
                result[key] != summary[field] for key, field in
                (('passed', 'passedTests'), ('failed', 'failedTests'))
            ) or result['skipped'] != summary['skippedTests'] + summary['expectedFailures']:
                raise ValueError('tree and summary counts differ')
            (args.root / 'report.json').write_text(json.dumps(result) + '\n')
            with args.summary.open('a') as output:
                output.write(summary_table(args.mode, [result]))
        else:
            needs = json.loads(args.needs.read_text())
            if not lane_needed(args.event, needs):
                with args.summary.open('a') as output:
                    output.write('iOS lane not needed: successful path classification.\n')
                return 0
            # Include failed/skipped/cancelled jobs even if they emitted no files.
            with args.summary.open('a') as output:
                output.write(f'\nMode: **{args.mode or "unavailable"}**.\n\n| Job | Conclusion |\n| --- | --- |\n')
                for job in ('changes', 'ios-build', 'ios-unit', 'ios-ui'):
                    output.write(f"| {job} | {needs.get(job, {}).get('result', 'missing')} |\n")
            reports = [json.loads(p.read_text()) for p in sorted((args.root / 'evidence').glob('*/report.json'))]
            with args.summary.open('a') as output:
                output.write(summary_table(args.mode, reports))
            require_success(needs)
            plan = json.loads((args.root / 'plan/plan.json').read_text())
            if args.mode != plan['mode']:
                raise ValueError('build mode does not match plan')
            verify_reports(plan, reports)
            print('All needed jobs succeeded; executed unit and UI unions match the build plan.')
        return 0
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f'iOS parallel evidence failed: {error}', file=sys.stderr)
        if args.command in ('report', 'aggregate'):
            with args.summary.open('a') as output:
                output.write(f'\nMode: **{args.mode or "unavailable"}**. Evidence verification failed; no passing result.\n')
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
