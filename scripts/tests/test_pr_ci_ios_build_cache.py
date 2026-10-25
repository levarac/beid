"""Cache trust boundaries and build execution on both hits and misses."""
import itertools
import re
import unittest

from scripts.tests.test_pr_ci_lane_skip import IOS, job_block
from scripts.tests.test_pr_ci_ios_macos_workflow import step_block


class IosBuildCacheTests(unittest.TestCase):
    def setUp(self):
        self.build = job_block(IOS, 'ios-build')
        self.assertIn('      - name: Restore dependencies cache\n', self.build,
                      'the build dependency cache is missing')

    def test_forks_failures_and_hits_never_save(self):
        for cache in ('dependencies', 'swift-packages', 'gradle-build'):
            block = step_block(self.build, 'Save ' + cache + ' cache')
            condition = re.search(r'if: \$\{\{ (.+) \}\}', block).group(1)
            for event, head, succeeded, hit in itertools.product(
                    ('pull_request', 'merge_group', 'push', 'schedule', 'workflow_dispatch'),
                    ('levarac/beid', 'outside/beid'), (False, True), ('true', 'false', '')):
                values = {'github.event_name': event, 'github.repository': 'levarac/beid',
                          'github.event.pull_request.head.repo.full_name': head,
                          f'steps.{cache}.outputs.cache-hit': hit}
                expression = condition.replace('success()', repr(succeeded))
                expression = re.sub(r'\b(?:github|steps)(?:\.[\w-]+)+',
                                    lambda m: repr(values[m.group()]), expression)
                expression = expression.replace('&&', ' and ').replace('||', ' or ')
                actual = eval(expression, {'__builtins__': {}}, {})
                expected = succeeded and hit != 'true' and (event != 'pull_request' or head == 'levarac/beid')
                self.assertEqual(actual, expected, (cache, event, head, succeeded, hit))

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

    def test_exact_keys_separate_toolchains_sources_and_dependency_inputs(self):
        context = step_block(self.build, 'Identify cache inputs')
        for token in ('xcodebuild -version', '--show-sdk-build-version',
                      'java" -version', 'sw_vers -buildVersion', 'HEAD^{tree}'):
            self.assertIn(token, context)
        for cache in ('dependencies', 'swift-packages', 'gradle-build'):
            restore = step_block(self.build, 'Restore ' + cache + ' cache')
            save = step_block(self.build, 'Save ' + cache + ' cache')
            self.assertIn('steps.cache-inputs.outputs.toolchain', restore)
            self.assertNotIn('restore-keys:', restore)
            self.assertIn(f'steps.{cache}.outputs.cache-primary-key', save)
            self.assertEqual(restore.split('          path: |\n')[1].split('          key:')[0],
                             save.split('          path: |\n')[1])
        dependencies = step_block(self.build, 'Restore dependencies cache')
        for token in ('**/*.gradle', '**/gradle.properties', '**/gradle-wrapper.*',
                      '**/gradlew*', '**/*.toml', 'scripts/**'):
            self.assertIn(token, dependencies)
        packages = step_block(self.build, 'Restore swift-packages cache')
        self.assertIn('**/Package.resolved', packages)
        self.assertIn('ios/project.yml', packages)
        self.assertIn('ios/Beid.xcodeproj/project.pbxproj', packages)
        self.assertIn('steps.cache-inputs.outputs.source-tree',
                      step_block(self.build, 'Restore gradle-build cache'))

    def test_cached_paths_cannot_contain_test_results_or_test_products(self):
        expected = {
            'dependencies': ['${{ runner.temp }}/beid-gradle/wrapper/dists',
                             '${{ runner.temp }}/beid-gradle/caches/modules-2', '~/.konan'],
            'swift-packages': ['${{ runner.temp }}/beid-swift-packages'],
            'gradle-build': ['${{ runner.temp }}/beid-gradle/caches/build-cache-1'],
        }
        for cache, paths in expected.items():
            restore = step_block(self.build, 'Restore ' + cache + ' cache')
            actual = restore.split('          path: |\n')[1].split('          key:')[0]
            self.assertEqual([line.strip() for line in actual.splitlines() if line.strip()], paths)
        self.assertIn("printf 'GRADLE_USER_HOME=%s\\n' \"$RUNNER_TEMP/beid-gradle\" >> \"$GITHUB_ENV\"", self.build)
        self.assertIn('GRADLE_OPTS: -Dorg.gradle.caching=true', self.build)
        resolve = step_block(self.build, 'Resolve pinned Swift packages')
        build = step_block(self.build, 'Build for testing')
        for block in (resolve, build):
            self.assertIn('-onlyUsePackageVersionsFromResolvedFile', block)
            self.assertIn('-clonedSourcePackagesDirPath "$RUNNER_TEMP/beid-swift-packages"', block)
        self.assertIn('git diff --exit-code -- ios/Beid.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved', resolve)
        self.assertIn('-disableAutomaticPackageResolution', build)
