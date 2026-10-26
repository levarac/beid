"""Cache trust boundaries and build execution on both hits and misses."""
import itertools
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import tarfile
import textwrap
import unittest

from scripts.tests.test_pr_ci_lane_skip import IOS, job_block
from scripts.tests.test_pr_ci_ios_macos_workflow import step_block
from scripts.ios_gradle_cache_inventory import inventory


def cache_paths(block):
    paths = re.search(r'^          path: \|\n((?:            .+\n?)+)', block, re.M).group(1)
    return [line.strip() for line in paths.splitlines()]


class IosBuildCacheTests(unittest.TestCase):
    def setUp(self):
        self.build = job_block(IOS, 'ios-build')
        self.assertIn('      - name: Restore dependencies cache\n', self.build,
                      'the build dependency cache is missing')

    def test_forks_failures_and_hits_never_save(self):
        for cache in ('dependencies', 'swift-packages', 'gradle-build'):
            block = step_block(self.build, 'Save ' + cache + ' cache')
            condition = re.search(r'if: \$\{\{ (.+) \}\}', block).group(1)
            for event, head, ref, succeeded, hit, within_limit in itertools.product(
                    ('pull_request', 'merge_group', 'push', 'schedule', 'workflow_dispatch'),
                    ('levarac/beid', 'outside/beid'), ('refs/heads/main', 'refs/heads/topic'),
                    (False, True), ('true', 'false', ''), ('true', 'false', '')):
                values = {'github.event_name': event, 'github.repository': 'levarac/beid',
                          'github.ref': ref,
                          'github.event.pull_request.head.repo.full_name': head,
                          'steps.gradle-cache-size.outputs.within-limit': within_limit,
                          f'steps.{cache}.outputs.cache-hit': hit}
                expression = condition.replace('success()', repr(succeeded))
                expression = re.sub(r'\b(?:github|steps)(?:\.[\w-]+)+',
                                    lambda m: repr(values[m.group()]), expression)
                expression = expression.replace('&&', ' and ').replace('||', ' or ')
                actual = eval(expression, {'__builtins__': {}}, {})
                expected = succeeded and hit != 'true' and (event != 'pull_request' or head == 'levarac/beid')
                if cache == 'gradle-build':
                    allowed = (event == 'schedule' or (event == 'push' and ref == 'refs/heads/main')
                               or (event == 'pull_request' and head == 'levarac/beid'))
                    expected = succeeded and hit != 'true' and within_limit == 'true' and allowed
                self.assertEqual(actual, expected,
                                 (cache, event, head, ref, succeeded, hit, within_limit))

    def test_cache_hits_never_replace_build_or_execution_evidence(self):
        for step in ('Resolve pinned Swift packages', 'Build for testing',
                     'Enumerate built tests and plan shards', 'Upload test products'):
            self.assertNotIn('if:', step_block(self.build, step), step)
        for job in ('ios-unit', 'ios-ui', 'ios-simulator'):
            text = job_block(IOS, job)
            self.assertNotIn('actions/cache', text)
            self.assertNotIn('cache-hit', text)
        build = step_block(self.build, 'Build for testing')
        self.assertIn('build-for-testing', build)
        self.assertIn('-hideShellScriptEnvironment', build)
        self.assertIn('-showBuildTimingSummary', build)
        self.assertNotIn('xcodebuild -quiet', build)

    def test_keys_and_restore_prefixes_separate_toolchains(self):
        context = step_block(self.build, 'Identify cache inputs')
        for token in ('xcodebuild -version', '--show-sdk-build-version',
                      'java" -version', 'sw_vers -buildVersion', 'HEAD^{tree}'):
            self.assertIn(token, context)
        for cache in ('dependencies', 'swift-packages', 'gradle-build'):
            restore = step_block(self.build, 'Restore ' + cache + ' cache')
            save = step_block(self.build, 'Save ' + cache + ' cache')
            key = re.search(r'^          key: (.+)$', restore, re.M).group(1)
            version = 'v2' if cache == 'dependencies' else 'v1'
            prefix = (f'beid-ios-{cache}-{version}-${{{{ runner.os }}}}-${{{{ runner.arch }}}}-'
                      '${{ steps.cache-inputs.outputs.toolchain }}-')
            self.assertTrue(key.startswith(prefix), key)
            if cache == 'swift-packages':
                self.assertNotIn('restore-keys:', restore)
            else:
                self.assertIn('          restore-keys: |\n', restore)
                prefixes = restore.split('          restore-keys: |\n')[1]
                self.assertEqual([line.strip() for line in prefixes.splitlines() if line.strip()],
                                 [prefix])
            self.assertIn(f'steps.{cache}.outputs.cache-primary-key', save)
            self.assertEqual(cache_paths(restore), cache_paths(save))
        dependencies = step_block(self.build, 'Restore dependencies cache')
        for token in ('**/*.gradle', '**/gradle.properties', '**/gradle-wrapper.*',
                      '**/gradlew*', '**/*.toml'):
            self.assertIn(token, dependencies)
        scripts = re.findall(r"'scripts/[^']+'", dependencies)
        self.assertEqual(scripts, ["'scripts/resolve_kmp_java_home.sh'"])
        packages = step_block(self.build, 'Restore swift-packages cache')
        self.assertIn('**/Package.resolved', packages)
        self.assertIn('ios/project.yml', packages)
        self.assertIn('ios/Beid.xcodeproj/project.pbxproj', packages)
        self.assertIn('steps.cache-inputs.outputs.source-tree',
                      step_block(self.build, 'Restore gradle-build cache'))

    def test_saves_follow_successful_build_enumeration_and_handoff(self):
        prerequisites = ('Build for testing', 'Enumerate built tests and plan shards',
                         'Pack portable test products and report size',
                         'Upload test products', 'Upload shard plan')
        for name in prerequisites:
            block = step_block(self.build, name)
            self.assertNotIn('continue-on-error:', block)
            self.assertNotIn('if:', block)
        for cache in ('dependencies', 'swift-packages', 'gradle-build'):
            block = step_block(self.build, 'Save ' + cache + ' cache')
            self.assertIn('success()', block)
            for prerequisite in prerequisites:
                self.assertLess(self.build.index('      - name: ' + prerequisite + '\n'),
                                self.build.index('      - name: Save ' + cache + ' cache\n'))

    def test_build_cache_size_gate_rejects_missing_empty_and_oversized_directories(self):
        self.assertIn('      - name: Check gradle-build cache size\n', self.build)
        block = step_block(self.build, 'Check gradle-build cache size')
        script = textwrap.dedent(block.split('        run: |\n')[1])
        self.assertLess(self.build.index('      - name: Check gradle-build cache size\n'),
                        self.build.index('      - name: Save gradle-build cache\n'))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cache = root / 'gradle/caches/build-cache-1'
            output, summary = root / 'output', root / 'summary'
            executable = root / 'du'
            # Exercise the actual workflow shell at the 512 MiB boundary without
            # allocating hundreds of MiB for the regression test.
            executable.write_text('#!/bin/sh\nprintf "%s\\tcache\\n" "$CACHE_TEST_KIB"\n')
            executable.chmod(0o755)
            for exists, kib, expected in ((False, 0, False), (True, 0, False),
                                          (True, 1, True), (True, 524288, True),
                                          (True, 524289, False)):
                if exists:
                    cache.mkdir(parents=True, exist_ok=True)
                output.write_text('')
                summary.write_text('')
                result = subprocess.run(['bash', '-c', script], capture_output=True, text=True,
                                        env={**os.environ, 'PATH': str(root) + os.pathsep + os.environ['PATH'],
                                             'GRADLE_USER_HOME': str(root / 'gradle'),
                                             'GITHUB_OUTPUT': str(output), 'GITHUB_STEP_SUMMARY': str(summary),
                                             'CACHE_TEST_KIB': str(kib)})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output.read_text().strip(),
                                 'within-limit=' + str(expected).lower(), (exists, kib))
                self.assertIn(str(kib), summary.read_text())

    def test_cached_paths_cannot_contain_test_results_or_test_products(self):
        expected = {
            'dependencies': ['${{ runner.temp }}/beid-gradle/wrapper/dists',
                             '${{ runner.temp }}/beid-gradle/caches/modules-2', '~/.konan',
                             '${{ runner.temp }}/beid-gradle/caches/*/kotlin-dsl',
                             '${{ runner.temp }}/beid-gradle/caches/*/groovy-dsl'],
            'swift-packages': ['${{ runner.temp }}/beid-swift-packages'],
            'gradle-build': ['${{ runner.temp }}/beid-gradle/caches/build-cache-1'],
        }
        for cache, paths in expected.items():
            restore = step_block(self.build, 'Restore ' + cache + ' cache')
            self.assertEqual(cache_paths(restore), paths)
        for block in re.split(r'\n      - ', self.build):
            if 'uses: actions/cache' in block:
                self.assertIn('actions/cache/restore@' if block.startswith('name: Restore')
                              else 'actions/cache/save@', block)
                self.assertNotRegex(block, r'(?i)xcresult|test-results|DerivedData|Build/Products')
        self.assertIn("printf 'GRADLE_USER_HOME=%s\\n' \"$RUNNER_TEMP/beid-gradle\" >> \"$GITHUB_ENV\"", self.build)
        self.assertIn('GRADLE_OPTS: -Dorg.gradle.caching=true', self.build)
        resolve = step_block(self.build, 'Resolve pinned Swift packages')
        build = step_block(self.build, 'Build for testing')
        for block in (resolve, build):
            self.assertIn('-onlyUsePackageVersionsFromResolvedFile', block)
            self.assertIn('-clonedSourcePackagesDirPath "$RUNNER_TEMP/beid-swift-packages"', block)
        self.assertIn('git diff --exit-code -- ios/Beid.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved', resolve)
        self.assertIn('-disableAutomaticPackageResolution', build)

    def test_input_fingerprints_are_enabled_before_gradle_starts(self):
        # Gradle initializes cache-key logging before evaluating init scripts.
        options = re.search(r'^      GRADLE_OPTS: (.+)$', self.build, re.M).group(1)
        self.assertIn('-Dorg.gradle.caching.debug=true', options.split())
        timing = Path('scripts/ci_gradle_timing.init.gradle').read_text()
        self.assertNotIn("System.setProperty('org.gradle.caching.debug'", timing)

    def test_gradle_diagnostics_keep_each_attempt_for_comparison(self):
        upload = step_block(self.build, 'Upload Gradle diagnostics')
        self.assertIn('name: ios-build-gradle-${{ github.run_attempt }}\n', upload)

    def test_ci_timing_is_installed_before_build_and_uploaded_on_failure(self):
        self.assertIn('GRADLE_OPTS: -Dorg.gradle.caching=true -Dorg.gradle.logging.level=info', self.build)
        install = step_block(self.build, 'Install Gradle diagnostics')
        report = step_block(self.build, 'Report Gradle diagnostics')
        upload = step_block(self.build, 'Upload Gradle diagnostics')
        self.assertLess(self.build.index(install), self.build.index('      - name: Build for testing\n'))
        self.assertLess(self.build.index('      - name: Build for testing\n'), self.build.index(report))
        for block in (report, upload):
            self.assertIn('if: ${{ always() }}', block)
        self.assertIn('name: ios-build-gradle', upload)
        self.assertIn('overwrite: true', upload)
        self.assertIn('path: ${{ env.CI_OUTPUT_ROOT }}/gradle/', upload)
        script = textwrap.dedent(install.split('        run: |\n')[1])
        root = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            environment = {**os.environ, 'GRADLE_USER_HOME': str(temp / 'gradle'),
                           'CI_OUTPUT_ROOT': str(temp / 'run-1'), 'GITHUB_ENV': str(temp / 'env')}
            result = subprocess.run(['bash', '-c', script], cwd=root, env=environment,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((temp / 'gradle/init.d/beid-timing.gradle').read_bytes(),
                             (root / 'scripts/ci_gradle_timing.init.gradle').read_bytes())
            self.assertEqual((temp / 'run-1/gradle/tasks.tsv').read_text(), 'task\toutcome\tseconds\n')
            self.assertEqual(json.loads((temp / 'run-1/gradle/cache-before.json').read_text()), [])
            self.assertIn('BEID_GRADLE_TIMING_FILE=' + str(temp / 'run-1/gradle/tasks.tsv'),
                          (temp / 'env').read_text())
            timings = temp / 'run-1/gradle/tasks.tsv'
            timings.write_text(timings.read_text() + 'configuration\tCOMPLETE\t1.234\n'
                               ':shared:link\tFROM-CACHE\t0.345\n:shared:broken\tFAILED\t0.001\n')
            result = subprocess.run(['bash', '-c', textwrap.dedent(report.split('        run: |\n')[1])],
                                    cwd=root, env=environment, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(':shared:link\tFROM-CACHE\t0.345', result.stdout)
            self.assertIn(':shared:broken\tFAILED\t0.001', result.stdout)
            self.assertEqual(json.loads((temp / 'run-1/gradle/cache-after.json').read_text()), [])
            # The workflow's logging pipe must retain xcodebuild's failure.
            executable = temp / 'bin/xcodebuild'
            executable.parent.mkdir()
            executable.write_text('#!/bin/sh\necho build-diagnostic\nexit "$FIXTURE_STATUS"\n')
            executable.chmod(0o755)
            build_script = textwrap.dedent(step_block(self.build, 'Build for testing').split('        run: |\n')[1])
            for status in (0, 73):
                result = subprocess.run(['bash', '-c', build_script], cwd=root,
                                        env={**environment, 'PATH': str(executable.parent) + os.pathsep + os.environ['PATH'],
                                             'RUNNER_TEMP': str(temp), 'SIMULATOR_UDID': 'fixture',
                                             'FIXTURE_STATUS': str(status)}, capture_output=True, text=True)
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertIn('build-diagnostic', (temp / 'run-1/gradle/build.log').read_text())
        for job in ('ios-unit', 'ios-ui', 'ios-simulator'):
            self.assertNotIn('beid-timing', job_block(IOS, job))

    def test_cache_inventory_identifies_tasks_and_tolerates_corruption(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            metadata = b'identity=\\:shared\\:link\nexecutionTime=1234\ngradleVersion=8.14\nhostName=ignored\n'
            with tarfile.open(root / ('a' * 32), 'w:gz') as archive:
                member = tarfile.TarInfo('METADATA')
                member.size = len(metadata)
                archive.addfile(member, io.BytesIO(metadata))
                # No output paths, including traversal names, are extracted.
                member = tarfile.TarInfo('../../untrusted-output')
                member.size = 4
                archive.addfile(member, io.BytesIO(b'data'))
            (root / ('b' * 32)).write_bytes(b'bad archive')
            (root / 'gc.properties').write_text('ignored')
            rows = inventory(root)
            self.assertEqual(len(rows), 2)
            self.assertEqual(rows[0]['identity'], ':shared:link')
            self.assertEqual(rows[0]['executionTime'], '1234')
            self.assertNotIn('hostName', rows[0])
            self.assertEqual(rows[1]['error'], 'ReadError')
            self.assertEqual(sorted(p.name for p in root.iterdir()), ['a' * 32, 'b' * 32, 'gc.properties'])
