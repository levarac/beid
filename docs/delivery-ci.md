# Delivery / CI contract (GitHub Actions + Xcode Cloud)

The platform delivery docs are `docs/xcode-cloud.md` for iOS and
`docs/google-play.md` for Android (canonical, each carries verification
dates). The contract every agent must know before touching delivery files:

## PR CI

All pull-request jobs use literal GitHub-hosted labels: `ubuntu-24.04-arm`
for classification, sanity and SwiftLint, `ubuntu-24.04` for Android,
`macos-26` for the lab CLI (Xcode 26.5), and `xcode-27` for iOS simulator
builds and tests (Xcode 27.2). No pull-request workflow receives secrets, including same-repository PRs.
Removing persistent runner access before public cutover is a separate operator
step; workflow edits alone cannot prevent a modified fork workflow from
requesting a runner that remains registered. All Actions references use reviewed full commit SHA pins with tag comments.
XcodeGen downloads verify `ios/ci_scripts/XCODEGEN_SHA256` before extraction.
See [CI dependency pins](ci-dependency-pins.md) for provenance.

- **この subsection が repository の PR CI lane 分担の正本。** 実行定義は
  `.github/workflows/pr-ci.yml` にある。現在の `pr-ci` はすべての PR と
  `main` への push、および `merge_group` の `checks_requested` で、
  変更パス判定、Android build、SwiftLint、Repository sanity の4ジョブを
  GitHub-hosted の Ubuntu で実行する。iOS シミュレータと lab CLI のビルド・テストは、
  それぞれ別の workflow が macOS で実行する。
  All three PR build workflows accept `merge_group` without workflow-level
  path filters. In `pr-ci.yml`, Determine changed paths compares the event's
  `merge_group.base_sha...head_sha` using the existing compare/classifier path.
  Android build and SwiftLint may skip only when successful classification
  proves them unaffected; Repository sanity always runs. Missing SHAs, API
  failures, truncated lists and classifier failures run all three gates. This
  is the smallest extension of the existing pinned comparison, and keeps the
  required Determine changed paths context reporting on the merge result.
  - Android build: `:shared:testAndroidHostTest`、
    `:app:testDebugUnitTest`、`:app:assembleDebug`、
    `:app:compileDebugAndroidTestKotlin` (instrumented test source を
    **compile だけする** 別 step。emulator は使わず実行もしない。
    `androidTest` source set は `assembleDebug` でも `testDebugUnitTest` でも
    compile されないため、この step が無いと device-lab の instrumented test が
    engine API の変更で壊れても CI が緑のままになる)、`:app:dependencyInsight`
    (`org.levarac:barnard` の `debugRuntimeClasspath` resolution を build と
    test の step とは別の `./gradlew` 呼び出しとして追加実行し、その出力を
    `scripts/check_barnard_dependency_provenance.py` で検証する。resolved
    version が `android/app/build.gradle.kts` の宣言と一致すること、
    force override / project・composite-build substitution /
    `mavenLocal()` による差し替えが無いことを確認し、published dependency
    が実際に何へ resolve したかを CI log に machine-checkable な証拠として
    残す — gh#110)。Private upstream comparison is explicitly **SKIPPED** in this workflow;
    this is not a passing comparison. `trusted-parallax-comparison.yml` runs
    `scripts/clone_parallax_pinned.sh`, the shared host suite, and
    `scripts/check_parallax_comparison_ran.py` only on trusted main push/manual
    events behind the `parallax-comparison` environment. Its token must be an
    environment secret; missing credentials fail the trusted lane.
    New main revisions supersede older comparison runs, including approval
    waiters; the replacement still requires environment approval. The
    concurrency group is per ref, so a manual dispatch from another branch
    does not cancel the main comparison. Re-running an older main comparison
    joins the same group and cancels a newer pending one, so re-run the
    latest instead.
    Android unit-test resource roots include `shared/src/commonTest/fixtures/`
    and `ios/BeidTests/Fixtures/venue-bundle-conformance/`. Non-documentation
    changes under either root run Android checks, including on merge groups;
    the iOS fixture root also continues to run iOS and SwiftLint checks.
    A separate `actions/cache` restores only the two Robolectric SDK jars in
    Gradle's dependency cache before the build and saves after successful jobs,
    including PRs. Its key and paths derive from `robolectricSdkVersions`;
    setup-gradle's PR cache remains read-only. Only `org.robolectric:android-all-instrumented`
    resolves from Google's Maven Central mirror first, then Central when absent.

  - SwiftLint runs `scripts/lint.sh` and `scripts/check_lint_fixtures.py` in
    the digest-pinned SwiftLint 0.65.0 image with its Linux SourceKit runtime.
    The same hosted job proves both lint fixtures: SwiftLint must exit 2,
    every fail marker must match its line and rule exactly, and the pass fixture
    and application must have zero violations. The checker itself exits 0
    only for that expected negative result; other exits or report drift fail.
  - repository sanity: XcodeGen YAML と TestFlight notes の JSON / 構造検証、
    `scripts/check_pr_ci_doc_drift.py` による本 subsection と workflow の
    drift 検査、`python3 -m unittest discover -s scripts/tests -t .` による
    `scripts/` の契約テスト (1 秒未満。gh#423 で追加するまで、この
    テスト群はどの workflow からも実行されていなかった)。**件数をここに書かない** —
    追加するたびに古くなり、しかもそれを検査するものが無い。drift 検出を説明する
    文書に、手で維持する数字を置かないこと

  - **`.github/workflows/pr-ci-lab-cli.yml`** — `beid-lab-cli build and test`
    runs `swift build -c release` and `swift test` on standard `macos-26`
    with Xcode 26.5. The job is created on every PR, including drafts, so its
    required context always reports. A small `Classify paths for lab CLI lane`
    job runs the same collection step and `scripts/ci_change_filter.py` as
    `Determine changed paths`, and the lane has a job-level `if:` on its
    output: it runs when the classifier reports `labcli`, `lint` or `error`,
    and is skipped (reported as skipped) otherwise, for example on a
    documentation-only PR. A failed classification job runs the lane. Main
    pushes retain the lab path filter and always build; manual dispatch always
    builds. On `merge_group`, the optional classifier is skipped and the
    required build/test job always executes, including documentation-only
    changes. Reusing the existing non-PR condition is simpler than another
    comparison path. This standalone package has its own lane so its result
    does not wait for the simulator suite.

  - **`.github/workflows/pr-ci-ios-macos.yml`** — `iOS simulator` is the
    hosted iOS PR gate. `pull_request` includes `opened`, `synchronize`,
    `reopened`, `ready_for_review`, `labeled`, and `closed`, with no
    path filter or draft guard.
    Adding `ci:full-ui` requests full coverage. Other label additions run only
    an Ubuntu summary step in an isolated group, even when the PR already has
    `ci:full-ui`. Closing or merging a PR cancels its outstanding iOS run by
    entering the same PR-number concurrency group. Both inactive event types
    expand a single matrix row named `iOS simulator (inactive)`. Only active
    events expand a row named `iOS simulator`. The inactive row has no checkout,
    test or artifact step.
    A `Classify paths for iOS lane` job runs the same collection step and
    `scripts/ci_change_filter.py` as `Determine changed paths`; the lane has a
    job-level `if:` driven by an independent `ios` output. Documentation-only
    PRs and PRs limited to Android app sources/resources skip macOS work;
    `iOS simulator` is a successful aggregate with an explicit classifier-skip
    summary only when classification succeeded with `ios=false,error=false`. The only
    non-documentation exclusions are `android/app/src/**` (after build-input
    rules) and the standalone `tools/beid-lab-cli/**`.
    On a PR update, classification compares the event's base and head. A PR
    that only edits `docs/delivery-ci.md` skips the iOS build and still runs
    the documentation drift check in Repository sanity. If the PR also changes
    UI tests, a final commit that only edits this document still requires iOS
    evidence. On a synchronize event the planner can carry an earlier execution
    under the rules below. Otherwise it builds and tests the new head.
    `android/settings.gradle.kts` includes only `:app` and `:shared`, with the
    latter mapped to `../shared`; `shared/build.gradle.kts` has no dependency
    on `:app`. `ios/project.yml` invokes only the shared Swift Export task,
    while `android/app/build.gradle.kts` depends on shared in the other
    direction. Gradle configures app even for that shared-only task, so app
    build inputs still run iOS: build/settings scripts, `gradle.properties`,
    `proguard-rules.pro`, other configuration inputs, any `*.gradle(.kts)` and
    `buildSrc`/`build-logic` paths. App paths outside `src/**` run conservatively.
    No app source/resource is currently read by the build scripts during
    configuration; adding such a read must also add a build-input rule before
    the source/resource exemption.
    There are no other Android-only modules or version catalogs today.
    New Android modules and catalogs are unclassified and run iOS.

    iOS-affecting inputs include `ios/**`, `shared/**`,
    `android/build.gradle.kts`, `android/settings.gradle.kts`,
    `android/gradle.properties`, `android/gradlew`, `android/gradle/wrapper/**`,
    and any version catalog (including `android/gradle/libs.versions.toml`).
    Workflow and script changes run conservatively, including the iOS workflow,
    classifier, JDK resolver, XcodeGen downloader/generation guard and simulator
    helper. Documentation retains the shared classifier's existing definition
    (`docs/**`, `.md`, `.mdx`, after force-all build-input rules).
    Unknown or malformed paths, empty lists, renames, deletions, missing or
    unrecognized API file metadata, truncated comparisons and API errors run
    iOS. Compare pagination is by commit; file metadata is validated only on
    the first page, which contains all changed files (up to the 300-file cap).
    Later pages without a files array do not force iOS to run. A missing,
    malformed or empty first-page file list and the 300-file cap still run iOS.
    Rename/deletion metadata affects only iOS; lab CLI selection is
    unchanged. Failed classification or a missing iOS output also runs iOS.
    The lane uses `!cancelled()` so a superseded run does not start a macOS job.
    Main pushes retain their iOS/build-input path filter (including catalogs,
    classifier and generation guard). A matching push reports the full iOS result
    and can credit a preceding merge-queue run on the identical commit. Manual
    dispatch executes the full suite. Nightly on main runs at 03:23 UTC, away from the busy top
    of the hour. All three workflows' concurrency groups include event name
    and ref (or PR number). A queue ref identifies its entry, so queue runs,
    PR synchronizations, main pushes, nightly and dispatch runs cannot cancel
    each other; same-event/ref superseded runs still cancel.
    The two classification jobs have their own names, distinct from
    `Determine changed paths`, because required contexts are keyed by job name;
    do not add them to the required list.
    All PR build lanes check out `github.event.pull_request.head.sha`
    explicitly; other events check out `github.sha`. On `merge_group`,
    GitHub defines `github.sha` as the merge-group head SHA and `github.ref`
    as its ref, so the existing checkout expression builds the merge result
    rather than a PR head. See [GitHub's event reference](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#merge_group).

    The `xcode-27` image uses `/Applications/Xcode_27.2.app` and
    requires the iOS 27.0 runtime. `scripts/ci_simulator.py` creates a new
    simulator for each job and returns its UDID; only that device is booted,
    tested and deleted, even on failure. Build-for-testing keeps Swift in
    Debug with `SWIFT_OPTIMIZATION_LEVEL=-O` and selects Release Kotlin/Native
    with `BEID_KMP_BUILD_TYPE=Release` for the Beid target's Gradle invocation.
    Smoke runs the checked-in UI list and `BeidTests` minus the three deferred suites in `scripts/ios_ui_smoke.py`; full runs both complete bundles.
    Deferred coverage paths, uncertain classifications, and the `ci:full-ui` label
    select full mode. Merge groups, main pushes, nightly and manual events
    also select full mode. On `merge_group`, the optional
    classifier is skipped and the required iOS job always executes, including
    documentation-only changes. This reuses the existing non-PR condition and
    guarantees full-suite evidence for the merge result. The existing run-name
    expression also displays full because only PR events can select smoke.
    Mode is selected once from the event and its SHA-pinned changed paths.
    The summary records the selected mode, per-bundle counts and
    summed xcresult Test Case durations (numeric `durationInSeconds` or the
    human-readable `duration`, excluding suite totals, not elapsed wall time).
    Missing duration evidence fails verification rather than reporting zero.
    The list stays outside all XcodeGen source roots, rejects empty/duplicate
    entries, and repository sanity checks every method against its Swift class.
    Smoke selection includes `-only-testing:BeidTests` and one exact UI method
    argument per entry. The structured xcresult summary must contain nonzero
    tests, consistent counts and a passing result. The execution ledger must
    match the selected unit and UI case IDs and their expected skips.

    Job graph: the optional classifier feeds `Plan iOS test jobs` (Ubuntu),
    then `Build iOS test bundles` (`xcode-27`). Smoke builds and runs its tests
    in that one macOS job. Full builds both bundles once, enumerates them with
    `xcodebuild -enumerate-tests`, then transfers a tar containing `Build/Products`
    and its `.xctestrun` to a matrix: one `unit` job and `ui-1` through `ui-N`.
    Each matrix job owns a fresh simulator, DerivedData and result bundle, uses
    `-xctestrun` without a project/package resolution, and disables Xcode's own
    parallel testing. Tar preserves executable permissions and symlinks. Before
    extraction, SHA, full Xcode version/build, SDK and architecture must match;
    absolute DerivedData/checkout references in `.xctestrun` are relocated.
    The matrix starts only after build finishes, has `fail-fast: false` and
    `max-parallel: 6`, and the iOS macOS jobs use the `xcode-27` label.
    The default `env.IOS_UI_SHARDS` value of `4` requests four UI jobs
    and one unit job after the build. They can start together when five
    macOS runners are free. A manual run of this workflow can choose 4 or 5
    UI jobs with `ui_shards`. Its matrix planner rejects other counts. The current weights put the
    longest lane at 56m48s with two jobs and 37m55s with three. Under the former
    40-minute UI limit, three jobs left only 2m05s for XCTest overhead.

    The shared manifest generator, `scripts/ios_ui_smoke.py shards`, accepts
    counts from 2 through 5. The single-runner release nightly uses `--count 2`
    to build its full-suite manifest. The generator balances methods longest-first using
    `scripts/ios-ui-durations.json`. The weights use hosted iPhone
    `test-tree.json` case durations. A new or changed test may use a projected
    weight until a hosted run measures it.
    Methods missing from the table get a 20-second weight. Identifier ordering
    and the lowest shard index break ties, so every new
    test is assigned exactly once. Runtime UI enumeration must also equal the
    current Swift source inventory. The four iPhone exclusions (portrait and
    landscape Records navigation, the landscape primary flow, and system window resizing) in
    `scripts/ios-ui-iphone-skips.txt` remain selected and must have result nodes;
    they must report their deliberate iPhone Skipped status. An unexecuted
    excluded case may omit duration (counted as zero); passed cases require it.
    Debug Simulator unit exclusions are listed with reasons in
    `scripts/ios-unit-debug-simulator-skips.txt`: guestFirst onboarding, the
    Release-only demo-mode assertion, and the opt-in local reference-operator
    integration (not configured in CI). Both modes keep these tests selected;
    each must exist and report Skipped. A listed test that passes fails as stale.

    The exact required name `iOS simulator` belongs to the Ubuntu
    aggregate. Full requires successful plan/build/matrix jobs, every expected
    shard artifact, and no repeated or unassigned UI case. Every enumerated test
    is checked; anything not on the per-environment skip list must pass. Missing, failed,
    cancelled or unexpectedly skipped jobs/cases fail the aggregate. Smoke
    requires build/test success in its one job and its exact execution ledger.
    On ready-for-review the workflow waits behind any active execution and can
    report a completed result from the same PR, head and mode. A recorded
    failure still fails the check. After a carried failure, select **Re-run all
    jobs** to run planning again and execute the tests. Retrying only the
    aggregate keeps the original plan and reports the same failure. Adding
    `ci:full-ui` requests a fresh run;
    later pushes with that label also require fresh full execution.

    The iOS classifier and planner check out the event's base SHA. Only the
    trusted base supplies the receipt lookup, path policy and mode checks.
    Pull-request changes to those tools or the iOS workflow require fresh
    execution. The aggregate validates carried evidence with the same base
    code. Fresh builds and tests still use the PR head.

    On synchronize, the planner looks up this workflow's original run and jobs
    through the read-only Actions API. Both revisions must belong to the same
    repository, PR and branch. The source plan must record the same base SHA,
    its tested head, requested mode and GitHub's synthetic PR merge SHA.
    The planner checks the parents of both synthetic commits and requires the
    workflow file to have the same Git blob at both revisions. The first attempt must have completed
    its build, tests and successful execution ledger. A previous inherited result
    cannot serve as evidence. The comparison from the tested SHA to the new head
    must prove direct ancestry and contain fewer than 300 files, all added or
    modified. Allowed changes are independent documentation, Android app sources
    or standalone lab CLI inputs, subject to the iOS build-input checks. PRs
    changing build inputs or CI code use fresh execution. The cumulative PR
    may change Swift app/test sources, shared Kotlin sources and independent
    paths. Forks, incomplete metadata and lookup
    failures and base revisions without the lookup helper fall back to fresh
    execution. The check name for unrelated labels and closed events is selected
    solely from the webhook payload, independently of skipped jobs. The check summary names the current
    head, tested SHA, run, attempt and mode. An explicit classifier skip remains
    a separate outcome. Merge groups, nightly and manual runs always execute.
    A source run from before base provenance was recorded
    can only satisfy an identical-head ready check.

    On the first attempt of an ordinary push to `main`, the planner looks up the
    latest run of this iOS workflow for the same commit on the repository's main
    merge queue. It must have succeeded before the push run was created. The
    successful queue attempt's job list must show a passing build-for-testing,
    unit lane, every UI shard and the aggregate's execution-ledger check.
    When GitHub re-runs failed jobs, it lists retained successes with new job
    IDs and the new attempt number. The push can credit those earlier successes
    together with the re-run jobs because the queue accepted their combined
    full-suite evidence for the same workflow run and commit. The push aggregate
    links to that attempt and the push starts no macOS jobs. An unsuccessful
    queue run, a different SHA, an older serial workflow, incomplete evidence
    or an unavailable API causes fresh execution. **Re-run all jobs** on the
    push also executes the suite. This takes effect on main after the release
    workflow merges into main.

    Both modes upload `ios-evidence-<attempt>-<lane>` artifacts: enumeration,
    manifest, xcresult tree/schema/summary, per-case durations, and build logs/
    phase timing JSONL where applicable (14 days). Full product tar is a
    separate `ios-products-<attempt>` artifact (3 days), never a cache. A shard
    retry uses the artifact name reported by its build job. The aggregate uses
    the most recent evidence for each lane within the same run. It requires
    evidence from the actual build attempt and rejects lanes older than that
    build.
    A failed full-mode UI test or result check also uploads
    `ios-xcresult-<attempt>-<shard>` for seven days when Xcode has written a
    bundle and its compressed archive fits within 250 MiB. A test step reaching
    its time limit can leave a partial bundle. Runner loss or expiration of the
    whole job can prevent upload. The aggregate reads only structured evidence.
    After a full build, **Compare proposed UI test selection** publishes
    `ios-ui-selection-<attempt>` for 14 days. The report records the proposed
    screen and test-file matches, additional estimated seconds above smoke,
    the final candidate IDs, and any observed failures outside either set.
    The hand-written `VIEWS` and `TEST_FILES` tables match changed screen and
    UI test sources. Unmapped iOS inputs (including shared helpers), missing
    or malformed changed-path data, renames/deletions flagged by the collector,
    or an estimate over 25 additional minutes expand the final proposal to the
    full UI inventory. The report retains the original matches so a fallback
    can be distinguished from what the mapping itself covered. Expected iPhone
    skips remain listed at zero cost. Missing shard results are marked as
    incomplete evidence and do not alter the proposal. This Linux job runs
    after the full test jobs when the full build succeeded, including when
    tests failed. Smoke runs skip it. It has its own check result and the
    required iOS check has no dependency on it.
    Use “Re-run all jobs” to recreate expired artifacts.
    `scripts/ios_ci_timing.py` timestamps SPM resolution,
    KMP script start/end, and the observed Swift compile window. That window
    includes overlapping/link work; `-showBuildTimingSummary` in `build.log`
    gives actual task durations. Job timeouts are 50 minutes for build/smoke and
    55 per full test job, including diagnostic upload and cleanup. Step timeouts are 35 minutes for build (the Release Kotlin
    framework alone takes about 12 minutes on `xcode-27`), 10 for smoke tests,
    and 40 for the full-mode unit lane. PR #967's four UI shards each planned
    about 28 minutes of test-case time. The 45-minute UI step limit is timeout
    containment for slow hosted `xcode-27` runs like #965 ui-3 and #967 ui-4,
    which hit 40 minutes on 2026-11-27, and leaves time for evidence and cleanup.
    On 2026-11-25 single tests stalled for 2 to 5 minutes on hosted runners,
    exhausting a 30-minute shard limit after two stalls. Hosted full and smoke
    timing and artifact portability still need measurement on the final SHA.

    ### Hosted UI query timeouts

    [Issue #949](https://github.com/levarac/beid/issues/949) tracks
    `Failed to get matching snapshot: Timed out while evaluating UI query.`
    and the equivalent message with `snapshots`. Named XCTest activities
    mark the demo advances, screen transitions and assertions in the reported
    test paths. Open the original result's activity log to identify the last
    started operation and record the query or screen in the issue.

    For a release PR, the CI owner may retry a failed UI lane once on the
    original full run. Before retrying, check that the run is complete at
    attempt 1 on the current PR head. The build, unit lane and all other UI
    lanes must be successful. Check that the failed lane has complete
    structured results, its failed cases are outside the PR's changed code
    paths, and every failure has the exact query-timeout message above.
    Assertion failures, launch or termination errors, and missing or mixed
    evidence follow the normal failure investigation.

    Retain the first failing job link, manifest, structured result and raw
    `.xcresult` under their original attempt-1 names. Save a copy of the first
    failure artifacts with their SHA-256 digests before retrying, and confirm
    the build products and successful lane evidence remain available in Actions.
    Use **Re-run job** on the failed UI lane. To use the CLI, run
    `gh run view RUN_ID --repo levarac/beid --attempt 1 --json jobs` and find
    the failed lane's `databaseId` by its `name`. Pass that ID to
    `gh run rerun RUN_ID --job FAILED_JOB_ID --repo levarac/beid`.
    GitHub reuses the build's products and reruns the dependent checks. The
    lane runs its full manifest on a fresh simulator with the existing limits.

    Record the two job links, the first failed test IDs and both outcomes.
    Require the retried lane and the normal aggregate check to pass. Keep a
    passing retry visible as a recovery in #949 and leave it out of the
    consecutive clean-run count. If the second attempt fails or is incomplete,
    leave the run red and investigate the retained evidence.

    On pushes to `release/1.1.0`, `ios-release-cache-seed.yml` populates the
    Gradle distribution, KMP dependencies and SwiftPM checkouts with the same
    cache keys and paths as the PR build. It also builds the arm64 Debug
    Simulator products with Release Kotlin and Swift optimization `-O`. It
    saves a separate compiler CAS snapshot at most once per toolchain and ISO
    week, and a Kotlin Swift Export snapshot for each complete input digest.
    The Xcode phase permits export installation only on a GitHub-hosted
    Actions runner. Local, device and self-hosted builds use Gradle.
    The seed checks all five entries against GitHub's release-ref cache index,
    including the archive version for the action's input paths and compression.
    A dependency restore miss triggers population. Dependency saves are
    independent of optional CAS or Swift Export packing failures.
    A snapshot key ends with the SHA-256 of its archive. Using that digest
    requires a matching key and compatible version in the release index.
    The Actions restore step first extracts the outer cache archive. The digest
    check authenticates the inner payload after that extraction. Consumers
    belong only in disposable, unprivileged GitHub-hosted PR jobs.
    The export fingerprint
    also covers the Gradle artifacts, shared sources, Xcode project, host tools,
    SDK and JDK. Test bundles, results and DerivedData are excluded.

    PR builds targeting `release/1.1.0` only restore these five cache families.
    Compiler restore keys retain the exact toolchain prefix across weekly
    snapshots. The Swift Export prefix additionally requires an exact
    Kotlin input fingerprint, including resolved dependencies. Before enabling
    either one, the build checks the selected cache key against GitHub's
    release-scoped listing and verifies the complete archive against the SHA-256
    in that key. A missing entry, unavailable index or digest mismatch falls
    back to the regular build. A change to an individual Swift compiler input
    produces a new compiler key inside CAS. The normal build-for-testing,
    enumeration, per-case verification and required aggregate still run.

    The benchmark stored 124,823,225 bytes of compressed CAS and 3,592,270
    bytes of Swift Export, about 1.2% of a 10 GiB limit combined. Its Gradle distribution,
    broader v1 KMP cache and SwiftPM checkouts took another 1.63 GB. Record the
    dependency-only v2 KMP size from the first release seed.
    When a measurement finishes, retain its timing and case receipts, list
    caches with `gh cache list --ref refs/heads/BRANCH --limit 100`, and
    delete the measurement branch's entries by verified cache ID. The
    measurement owner coordinates cleanup with the maintainer authorized
    to remove those entries. Release and main entries remain available to PRs.

    Dependency caches are limited to downloaded Gradle module files in
    `~/.gradle/caches/modules-2/files-2.1`, Kotlin/Native host tools in
    `~/.konan/dependencies`, and SPM
    checkouts/repository objects under the stable runner-temporary
    `beid-spm/SourcePackages` path. KMP keys include Gradle catalog/wrapper,
    Kotlin declarations/build configuration, Xcode build, SDK build, JDK and
    runner architecture; SPM keys include `Package.resolved`, Xcode build and
    architecture. There are no prefix restore keys. SPM resolution uses the
    resolved file, and build-for-testing disables automatic package resolution.
    The iOS build separately restores Gradle distributions from
    `~/.gradle/wrapper/dists` using an exact OS, architecture, wrapper JAR and
    wrapper properties key. It invokes the checked-in wrapper before building
    and saves a new distribution immediately. A hit avoids the distribution
    download. A cold or evicted entry still requires a successful download,
    with one retry and the checksum from the wrapper properties.
    Build products move only through the artifact of the run's latest build
    attempt. Test results, DerivedData and execution ledgers are never cached.
    With the main merge queue enabled, the merge step is to add the PR to
    the queue after its required PR checks pass. A completed full-mode pass of
    `iOS simulator` on the queue's exact merge result satisfies the full-suite
    merge requirement; a PR smoke pass or path-classifier skip does not supply
    that evidence. Queue runs never skip the iOS job for paths. For an earlier
    full run before queueing, update the PR and then add `ci:full-ui`;
    `labeled` triggers a run on that head. Re-runs preserve the event's labels.
    If classification skips that PR run, dispatch the workflow on the same
    branch head for pre-queue full evidence. The workflow works before the
    label is created; label creation and queue settings are separate.

    Unsigned Release device compilation (`CODE_SIGNING_ALLOWED=NO`) remains
    in `main-ios-release-build.yml` on main push/manual dispatch, also using
    Xcode 26.5. It is not a PR status check or a signing/delivery lane.

  - **Xcode Cloud** — keep `PR Build & Test` paused. Hosted iOS now performs
    the build plus unit/UI smoke role on ordinary iOS-affecting PR heads and
    the full UI role on labeled PR heads,
    without signing secrets;
    the old ASC file exclusions no longer determine whether hosted evidence
    is required. This does not replace trusted Internal/Release delivery,
    signing or real-device BLE tests. ASC workflow settings are operator-owned
    and are not changed by this CI migration.

  **`scripts/check_pr_ci_doc_drift.py` checks all three PR build workflows**
  against `AGENTS.md`, including the separate iOS and lab CLI job names and
  distinguishing commands. The scripts unittest discovery command is checked
  in both directions, including whitespace and continued-line forms; an echo
  or comment mentioning it is not execution evidence. Trigger, head checkout, hosted runner and secret
  boundaries are guarded by the contract tests in `scripts/tests`.

  To run the script tests or documentation checker locally, install PyYAML
  into the active Python environment (a virtual environment is suitable):

  ```sh
  python3 -m pip install PyYAML==6.0.2
  python3 scripts/check_pr_ci_doc_drift.py
  python3 -m unittest discover -s scripts/tests -t .
  ```

  Required status checks on main: `Determine changed paths`,
  `Android build`, `SwiftLint`, `Repository sanity`, `iOS simulator`, and
  `beid-lab-cli build and test`. Android, lint and lab CLI may legitimately be
  skipped by their changed-path classifier; the iOS aggregate validates and
  reports its classifier skip as success. A skipped required check counts as
  passing. Do not require the
  main-only delivery, trusted comparison or Release compilation jobs, nor the
  release-notes metadata warning.

  The merge queue is active on `main` (ruleset `main merge queue`, id
  25775126, enforcement `active`): merge method `merge` (merge commit), build
  concurrency `1`, Only merge non-failing pull requests enabled, status check
  timeout `120` minutes, and merge limits minimum/maximum `1` PR, with the six
  required status checks above sourced from GitHub Actions. Merge commits are
  allowed in repository settings. Queue build concurrency is one to limit
  concurrent full macOS suites; it does not serialize jobs within a run. Pull
  requests enter the queue instead of being merged directly. See [GitHub's merge
  queue settings](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue).
- GitHub branch protection は approving review を merge 条件にしない。
  これは 2026-07-27 のオーナー判断による repository setting であり、
  上の KMP review gate を免除しない。KMP の independent review は作業上の
  gate、GitHub の approving review は merge button の設定で、別の条件である。

### Offline report for a failed hosted UI shard

Run `python3 -m scripts.ios_lifecycle_report <saved-job-directory>` with
Python 3.12. The command reads local evidence and writes JSON to stdout.
Its exit status describes report generation. The original job and required
iOS check keep their recorded conclusions.

Save the Actions API job response as `job.json` and its timestamped log as
`job.log`. For the same run and attempt, save the artifact metadata responses
for `ios-evidence-<attempt>-<ui shard>` and `ios-xcresult-<attempt>-<ui shard>`
as `structured.json` and `bundle.json`. Retain their original downloaded ZIP
bytes alongside them as `structured.zip` and `bundle.zip`. Repacking changes
the GitHub SHA-256 digest. Keep a separate directory for each job and obtain
the first attempt's artifacts before they expire.

A comparison candidate requires an executed UI shard with a complete case
ledger, exact expected skips, and agreement between the summary and test
tree on every failure. All failures must have the same exact application
launch-timeout or termination signature. The report records the original
artifact IDs and digests, manifest digest, failed case IDs, runner image,
simulator, and timings. Missing evidence or a mixed failure yields an
ordinary failure. This offline report starts no jobs.

### Delivery security boundary

TestFlight delivery runs only through Xcode Cloud Internal Build / Release Build.
The legacy `internal-testflight.yml` and `release-testflight.yml` Actions
workflows are removed. `scripts/gha/build-and-upload-ios.sh` remains a tested
operator helper with no Actions entrypoint. Reintroducing a signing-host fallback
requires a separate private repository and an owner decision; never reconnect a
persistent signing host to this public repository.

`internal-google-play.yml` uses disposable `ubuntu-24.04`, the
`google-play-internal` environment, `GHA_ANDROID_DELIVERY == on`, and main-only
push/manual events. Configure required human reviewers and a custom `main`
deployment branch policy before enabling it. Store `PLAY_KEYSTORE_B64`,
`PLAY_SERVICE_ACCOUNT_JSON_B64`, `PLAY_KEYSTORE_PASSWORD`, and
`PLAY_KEY_PASSWORD` only as environment secrets. The private Parallax token
belongs only to `parallax-comparison`, with the same reviewer/main restrictions.
Environment names in YAML do not create protection rules automatically.

During public cutover, keep Actions disabled and all Xcode Cloud workflows
paused while the owner detaches repository/organization persistent runner
access, removes repository-wide delivery secrets, configures environments,
restricts allowed Actions and requires SHA pins. The Xcode Cloud PR workflow
must remain paused until a credential-free fork boundary is verified; public
PR code is covered by the hosted Actions simulator lane. Internal/Release
workflows may resume only after repository linkage and trusted start conditions
are read back. Saving full Xcode Cloud workflow attributes before PATCH is
mandatory because omitted start conditions can be removed by an update.

These are operator settings gates, not completed by this code change. Attachment
review, exact-head CI, and the owner's transfer/publication approval are also
required before cutover. Workflow default token permissions must be read-only,
with PR-review approval disabled; fork approval must cover all external
contributors. Only the metadata-only `pull_request_target` comment job receives
`pull-requests: write`, and it never checks out repository code.

### Android delivery

The protected hosted workflow builds/signs the AAB and uploads to Google Play
internal testing after a main-only trigger and human environment approval.
It retains the two-file push filter (`what_to_test.json` and
`what_to_test.android.json`) plus manual execution on main. Workflow or script
edits alone do not trigger delivery. The resolver selects the job-installed
JDK 17. Environment credentials are materialized under `RUNNER_TEMP` with
restricted file permissions; values must never appear in logs.

### Delivery notes and versioning

- **"Ship a TestFlight test build" = update `what_to_test.json`** (repo
  root). Xcode Cloud publishes its text through
  `ios/TestFlight/WhatToTest.<locale>.txt`; the Android lane publishes it as
  Google Play release notes. Triggering delivery still requires owner approval.
  Neither publication has yet been observed by a tester; that observation is
  dispatch#29's gate. Rewrite
  the file wholesale each time — what to check in *this* build
  only, 1-3 plain sentences (ASC locale: `en-US` only), no PR
  numbers, no internal jargon, no accumulated history.
- **`release_notes.json` is App Store "What's New" copy.** On non-release
  branches it is never delivered to testers and editing it neither
  triggers nor annotates test builds. Caveat: on `release/*` branches the
  current `ci_post_xcodebuild.sh` sources TestFlight notes from
  `release_notes.json` instead (a legacy pattern slated for revision in
  issue #55 — the sister project that originated it abandoned it after
  shipping stale tester notes for 19 hours through exactly this file
  confusion). When in doubt, the file you want is `what_to_test.json`.
- **Versioning**: `MARKETING_VERSION` lives once, in `ios/Version.xcconfig`,
  which `ios/project.yml` makes the base of every build configuration (the
  project is xcodegen-generated — never hand-edit the `.xcodeproj`). A
  version bump edits that file only. Xcode Cloud builds use the Xcode Cloud
  run number. `CURRENT_PROJECT_VERSION` in the same file remains an inert
  placeholder (`1`) — leave it, never bump it per build.
- **"Uploaded" ≠ "delivered"**: a build can be `VALID` in App Store
  Connect yet reach no tester. Internal builds auto-deliver to the "Dev"
  TestFlight group via the ASC workflow post-action (configured
  2026-07-23; permanence re-confirmed per issue #37); verify group
  assignment through `GET /v1/betaGroups/{id}/builds` (the reverse
  direction reads empty for internal groups).
- **ASC GUI is the source of truth for workflow settings** — they are not
  in this repo and can drift from the docs. When observed behavior
  contradicts `docs/xcode-cloud.md`, trust App Store Connect, then update
  the doc with a new verification date.
- Release-branch conventions (`release/X.Y.Z` stabilization branches,
  version rules, CI guards) are being established in issue #55 — read it
  before doing release work.
- **Code signing / team ID**: `DEVELOPMENT_TEAM` in `ios/project.yml` is
  the maintainer's personal Apple Developer team. To build on a device
  with a different account, change the team locally (Xcode signing pane
  or a local `project.yml` edit + `xcodegen generate`) — but **never
  commit a team-ID change**. PRs that touch `DEVELOPMENT_TEAM`, bundle
  identifiers, or signing settings are rejected unless the maintainer
  authored them.
