"""Cache trust boundaries and build execution on both hits and misses."""
import itertools
import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest

from scripts.tests.test_pr_ci_lane_skip import IOS, job_block
from scripts.tests.test_pr_ci_ios_macos_workflow import step_block


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
            prefix = (f'beid-ios-{cache}-v1-${{{{ runner.os }}}}-${{{{ runner.arch }}}}-'
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

    def test_both_xcode_phases_stream_unique_outcomes_and_preserve_failure(self):
        root = Path(__file__).resolve().parents[2]
        spec = (root / 'ios/project.yml').read_text()
        fixture = ('> Task :shared:compileKotlinIosSimulatorArm64\n'
                   '> Task :shared:compileKotlinIosSimulatorArm64 FROM-CACHE\n'
                   '> Task :shared:compileSwiftExportMainKotlinIosSimulatorArm64 FROM-CACHE\n'
                   '> Task :shared:linkSwiftExportBinaryDebugStaticIosSimulatorArm64 FROM-CACHE\n'
                   '> Task :shared:unchanged UP-TO-DATE\n'
                   '> Task :shared:configuration SKIPPED\n'
                   '> Task :shared:resources NO-SOURCE\n'
                   '> Task :shared:swiftExport\n'
                   'warning: retain the original diagnostics\n')
        for target in ('Beid', 'BeidLab'):
            block = spec.split(f'  {target}:\n', 1)[1].split('    dependencies:', 1)[0]
            script = re.search(r'        script: \|\n((?:          .*\n)+)', block).group(1)
            script = textwrap.dedent(script)
            shell = re.search(r'        shell: (\S+)\n', block).group(1)
            for status in (0, 73):
                with self.subTest(target=target, status=status), tempfile.TemporaryDirectory() as directory:
                    project = Path(directory)
                    for name in ('ios', 'android', 'scripts', 'jdk/bin'):
                        (project / name).mkdir(parents=True)
                    summary = root / 'scripts/gradle_task_summary.awk'
                    if summary.exists():
                        (project / 'scripts/gradle_task_summary.awk').write_bytes(summary.read_bytes())
                    resolver = project / 'scripts/resolve_kmp_java_home.sh'
                    resolver.write_text('#!/bin/sh\nprintf "%s\\n" "$FIXTURE_JDK"\n')
                    resolver.chmod(0o755)
                    java = project / 'jdk/bin/java'
                    java.write_text('#!/bin/sh\nexit 0\n')
                    java.chmod(0o755)
                    gradle = project / 'android/gradlew'
                    gradle.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$FIXTURE_ARGS"\n'
                                      'cat "$FIXTURE_OUTPUT"\nexit "$FIXTURE_STATUS"\n')
                    gradle.chmod(0o755)
                    output = project / 'output'
                    output.write_text(fixture + ('> Task :shared:broken FAILED\n' if status else ''))
                    arguments = project / 'arguments'
                    result = subprocess.run(
                        [shell, '-c', script], capture_output=True, text=True,
                        env={**os.environ, 'SRCROOT': str(project / 'ios'),
                             'FIXTURE_JDK': str(project / 'jdk'), 'FIXTURE_ARGS': str(arguments),
                             'FIXTURE_OUTPUT': str(output), 'FIXTURE_STATUS': str(status)})
                    self.assertEqual(result.returncode, status, result.stderr)
                    self.assertIn(output.read_text(), result.stdout)
                    self.assertIn('Gradle tasks: FROM-CACHE=3 UP-TO-DATE=1 EXECUTED=1 '
                                  f'SKIPPED=1 NO-SOURCE=1 FAILED={int(bool(status))}', result.stdout)
                    self.assertEqual(arguments.read_text().splitlines(),
                                     [':shared:embedSwiftExportForXcode', '--no-daemon', '--console=plain'])
