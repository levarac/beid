# Delivery / CI contract (GitHub Actions + Xcode Cloud)

The platform delivery docs are `docs/xcode-cloud.md` for iOS and
`docs/google-play.md` for Android (canonical, each carries verification
dates). The contract every agent must know before touching delivery files:

## PR CI

All pull-request jobs use literal GitHub-hosted labels: `ubuntu-24.04-arm`
for classification/sanity, `ubuntu-24.04` for Android, `macos-26` for
SwiftLint and the lab CLI (Xcode 26.5), and `xcode-27` for iOS simulator
builds and tests (Xcode 27.2). No pull-request workflow receives secrets, including same-repository PRs.
Removing persistent runner access before public cutover is a separate operator
step; workflow edits alone cannot prevent a modified fork workflow from
requesting a runner that remains registered. All Actions references use reviewed full commit SHA pins with tag comments.
XcodeGen downloads verify `ios/ci_scripts/XCODEGEN_SHA256` before extraction.
See [CI dependency pins](ci-dependency-pins.md) for provenance.

- **この subsection が repository の PR CI lane 分担の正本。** 実行定義は
  `.github/workflows/pr-ci.yml` にある。現在の `pr-ci` はすべての PR と
  `main` への push、および `merge_group` の `checks_requested` で、
  GitHub-hosted Linux/macOS 上に次の gate を実行する。
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

  - SwiftLint: `scripts/lint.sh` and `scripts/check_lint_fixtures.py`.
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
    `reopened`, `ready_for_review`, and `labeled` (not `unlabeled`), with no
    path filter or draft guard.
    Thus every PR creates the `iOS simulator` context for branch protection.
    A `Classify paths for iOS lane` job runs the same collection step and
    `scripts/ci_change_filter.py` as `Determine changed paths`; the lane has a
    job-level `if:` driven by an independent `ios` output. Documentation-only
    PRs and PRs limited to Android app sources/resources skip macOS work;
    `iOS simulator` is a successful aggregate with an explicit classifier-skip
    summary only when classification succeeded with `ios=false,error=false`. The only
    non-documentation exclusions are `android/app/src/**` (after build-input
    rules) and the standalone `tools/beid-lab-cli/**`.
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
    classifier and generation guard) and always run the lane; manual dispatch
    always runs it. Nightly on main runs at 03:23 UTC, away from the busy top
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
    select full mode. Merge groups, push,
    nightly and manual events always run full. On `merge_group`, the optional
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
    The default `env.IOS_UI_SHARDS` value of `5` gives one unit job and five UI
    jobs. Set it to `4`, `3`, or `2` for smaller matrices. Values outside 2–5
    fail planning.

    `scripts/ios_ui_smoke.py shards` balances methods longest-first using
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

    The exact required name `iOS simulator` belongs to an `if: always()` Ubuntu
    aggregate. Full requires successful plan/build/matrix jobs, every expected
    shard artifact, and no repeated or unassigned UI case. Every enumerated test
    is checked; anything not on the per-environment skip list must pass. Missing, failed,
    cancelled or unexpectedly skipped jobs/cases fail the aggregate. Smoke
    requires build/test success in its one job and its exact execution ledger.
    Only a successful explicit PR classifier skip exempts test execution;
    merge groups and pushes never take that exception. `cancel-in-progress`
    remains enabled and no shard result is treated as passing after cancellation.

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
    and 40 for each full-mode test lane, leaving time for evidence and cleanup.
    UI shards plan at about 20 minutes of test-case time, but on 2026-11-25
    single tests stalled for 2 to 5 minutes on hosted runners, and 30 minutes
    was not enough for a shard with two stalls.
    These are containment, not claimed speed; hosted full and smoke timing and
    artifact portability still need measurement on the final SHA.

    Dependency caches are limited to `~/.gradle/caches` (excluding task build
    caches/execution history), `~/.konan`, and SPM
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
