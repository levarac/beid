# Delivery / CI contract (GitHub Actions + Xcode Cloud)

The platform delivery docs are `docs/xcode-cloud.md` for iOS and
`docs/google-play.md` for Android (canonical, each carries verification
dates). The contract every agent must know before touching delivery files:

## PR CI

All pull-request jobs use literal GitHub-hosted labels: `ubuntu-24.04-arm`
for classification/sanity, `ubuntu-24.04` for Android, and `macos-26` for
SwiftLint, iOS and the lab CLI (Xcode 26.5). No pull-request workflow receives secrets, including same-repository PRs.
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

  - SwiftLint: `scripts/lint.sh`
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
    final aggregate for the hosted iOS PR gate. `pull_request` includes `opened`, `synchronize`,
    `reopened`, `ready_for_review`, and `labeled` (not `unlabeled`), with no
    path filter or draft guard.
    Thus every PR creates the `iOS simulator` context for branch protection.
    A `Classify paths for iOS lane` job runs the same collection step and
    `scripts/ci_change_filter.py` as `Determine changed paths`; the build has a
    job-level `if:` driven by the independent `ios` output. Documentation-only
    PRs and PRs limited to Android app sources/resources skip the build/test
    work; the always-running `iOS simulator` aggregate validates that bypass
    and reports success. The only
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
    The build uses `!cancelled()` so a superseded run does not start a macOS job.
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

    The job graph is classifier → `iOS simulator build` → parallel
    `iOS unit shard ${{ matrix.shard }}` and `iOS UI shard ${{ matrix.shard }}` → `iOS simulator`.
    The aggregate explicitly needs the classifier, build, unit and UI matrices,
    runs with `always()` on Linux, and retains the only required iOS name.
    Classifier timeout remains 10 minutes; build and each test job are
    30 minutes, aggregate 5 minutes. Run 40163436992 attempt 1 measured a
    913-second build, 1122-second unit job and 1069/837-second UI jobs. The new
    unit shards retain the same 30-minute timeout and fresh-simulator ownership.
    Matrix fail-fast is disabled so one failure cannot hide
    another shard's evidence. The standard `macos-26` image uses
    `/Applications/Xcode_26.5.app` and iOS 26.5 in every build/test job.

    One `build-for-testing` uses `SWIFT_OPTIMIZATION_LEVEL=-O`, then enumerates
    both compiled test bundles with `test-without-building -enumerate-tests`.
    `scripts/ios_test_shards.py` creates deterministic longest-duration-first
    shards, with identifier tie breaks and unknown cases assigned to the
    lighter shard. Empty/duplicate inventories and non-exact shard unions fail.
    Full has two UI jobs; smoke has one, since eight cases do not justify a
    second artifact download and simulator startup. Both run alongside the
    two BeidTests shards in both modes. Unit partitioning selects whole classes,
    weights each class by the sum of its methods' measured durations, and uses
    stable class identifier ties. ReportSubmissionOperatorIntegrationTests stays
    together. The plan records both method inventories and class selectors;
    both unit shard union and class ownership must be exact. Xcode's own
    parallel testing is disabled: each test
    job creates, boots, tests and deletes only its owned simulator. Result
    bundles and JSON paths live outside DerivedData and include job/shard IDs.

    The build handoff is `products.tar.gz`: the `.xctestrun` file and runtime
    `Build/Products` tree, preserving executable permissions and symlinks.
    It excludes dSYMs, loose compiler outputs, intermediates, dependency caches
    and other DerivedData contents. Absolute Products references in the plist
    are relocated to `__TESTROOT__`; external product symlinks fail packaging.
    Its actual compressed byte/MiB size is printed in the build summary;
    run 40166483245 measured about 24.7 MB (23.6 MiB). Upload uses compression
    level zero because the tar is already compressed. Consumers download and
    extract it and use `-xctestrun`, with no project or DerivedData argument.
    Separate small plan and per-job evidence artifacts carry the inventory,
    assignments, raw xcresult summary/tree/schema JSON and per-case durations.
    Products are retained one day and evidence seven days. Run-scoped names
    `ios-products`, `ios-plan`, and `ios-evidence-<job>` use `overwrite: true`.
    Partial reruns reuse the existing build products and plan; the aggregate
    reads each job's latest evidence and shows its producing run attempt.
    Current `needs` results must all succeed, even if older passing evidence
    exists; every successful job's evidence must exist and match the plan.

    `ios/ci/ui-test-durations.tsv` and `ios/ci/unit-test-durations.tsv` are
    outside XcodeGen source roots. Both contain per-test durationInSeconds
    extracted from raw Test Case nodes in run 40163436992 attempt 1's evidence,
    with the source run recorded in comments: 66 UI rows (1364.541 seconds) and
    898 unit rows (763.618 seconds, including three existing skipped/expected
    cases). Full UI balances to 33/33 cases at 683.658/680.883 seconds; smoke
    selects eight cases at 132.211 seconds. Unit classes split 1/94 with 20/878
    cases at 500.287/263.331 seconds. The 500.287-second integration class is
    deliberately indivisible. Unknown methods retain estimated bundle-mean
    weights and remain visible as unmeasured; these sums exclude suite totals
    and do not predict simulator startup or artifact transfer by themselves.
    UI source inspection found no inter-test data/order prerequisite: each
    method launches with `-beid-ui-test`; onboarding restoration is bypassed,
    ProofStore/presence reset, report-link and venue files isolated per launch.
    The proof relaunch regression stays within one test method, not across
    tests. No app code or test ordering change is needed for the partition.

    Every test run assigns all BeidTests exactly once across two unit jobs. Ordinary
    `pull_request` events select `ios/ci/ui-smoke-tests.txt`; the payload label
    `ci:full-ui` selects full UI coverage. Merge groups, push, nightly and manual
    events always select full. Mode is computed once from the immutable event
    file, fails closed to full, and reaches every test job as a build output;
    re-runs retain the original payload mode and the run name still shows it.
    The existing path classifier alone may bypass PR work; merge groups always
    run the full lane even for documentation-only changes.

    Each job reports mode, bundle counts and summed xcresult Test Case durations
    (numeric `durationInSeconds` or human-readable `duration`, no suite totals).
    The aggregate prints a table across jobs, recomputes evidence from the raw
    trees, and compares both bundle unions after downloading every shard report.
    Each unit shard must execute exactly its assigned methods; missing, extra,
    duplicated or misassigned unit methods fail. Existing unit skip/expected
    failure accounting is preserved. A partial rerun of one unit shard reuses
    the other shard and UI reports from the same run; attempt numbers may differ.
    Smoke must equal the list exactly with every case Passed; full must execute
    every built UI case, including every smoke entry, exactly once and Passed.
    The aggregate succeeds only for a successful PR classifier's explicit
    `ios=false` with no error, or successful build, all unit and all UI jobs plus
    valid evidence. Failed/missing classification cannot authorize a bypass.
    Failed, cancelled, skipped or missing needed jobs; missing/duplicate shard
    reports; wrong mode/bundle; zero/inconsistent counts; missing durations;
    duplicate, extra, missing or skipped UI cases all fail closed.

    Build caches are confined to `iOS simulator build`; test jobs and the
    aggregate never restore caches. Three caches use the existing
    `actions/cache` v4 SHA with separate restore/save actions:
    - Dependencies: a dedicated `$RUNNER_TEMP/beid-gradle` home's
      `wrapper/dists` and `caches/modules-2`, plus `~/.konan` (Kotlin/Native
      distributions, downloaded native dependencies and platform caches).
      The dependency cache also retains `caches/*/kotlin-dsl` and
      `caches/*/groovy-dsl`, the compiled build scripts. Restoring downloaded
      artifacts alone repeats script compilation on every job. These add about
      4.3 MiB uncompressed, without project execution history. The whole version
      directory, generated API JARs, transforms, file-hash state and project
      `.gradle` are excluded. Existing prefix hits remain compatible and seed
      the missing DSL entries on the next successful save.
      The key hashes all Gradle scripts/properties/wrappers, TOML catalogs,
      `scripts/resolve_kmp_java_home.sh` and this workflow. The JDK resolver is
      the only repository script called by the Xcode build phases; Gradle
      invokes no repository scripts. Unrelated Python edits do not invalidate
      dependencies. A toolchain prefix restores the latest compatible entry
      when the exact key misses. Gradle verifies module artifacts and native
      toolchains use versioned directories; configuration is still evaluated.
      Compiled project outputs are not in this dependency cache.
    - Swift packages: `$RUNNER_TEMP/beid-swift-packages`, including checkouts,
      repositories and binary artifacts. Its key hashes every Package.resolved
      and Package.swift, project.yml, the generated project and this workflow.
      An explicit `-resolvePackageDependencies` step uses the lockfile, checks
      it stayed unchanged, and reports its own duration. The build uses the
      same directory and forbids automatic resolution to other versions.
    - Gradle build outputs: only the dedicated home's `caches/build-cache-1`,
      with `org.gradle.caching=true`. Its key includes the complete checked-out
      Git tree, with a toolchain prefix restore for newer trees. Gradle selects
      content-addressed task outputs by their full input hashes, so changed
      inputs rebuild while unchanged tasks can reuse an older tree's outputs.
      A hit never skips the Xcode invocation or its KMP phase.
      This home is populated only by build-for-testing, never by test tasks;
      it cannot import Android/host test-task results from another lane.

    All three keys also include a namespace version, runner OS/architecture
    and a fingerprint of the selected Xcode build, simulator SDK build, full
    JDK version and macOS build. Dependencies and Gradle build outputs restore
    only through that complete prefix; Swift packages remain exact-key only.
    No fallback crosses toolchains. Separate
    save steps run only after successful build, enumeration and upload, only
    on an exact-key miss (including a prefix hit). Dependencies and Swift
    packages save for non-PR events or a PR whose head repository equals this
    repository. Gradle build outputs save only on pushes to main, schedules,
    or same-repository PRs; never merge groups, fork PRs or manual dispatches.
    Fork PRs are restore-only, use no private credentials,
    and retain GitHub's PR cache-ref isolation; no pull_request_target build
    is introduced. PR caches and any merge-group dependency/package saves
    remain ref-scoped;
    default-branch caches can seed other refs, whose caches cannot seed main.
    Workflow guards do not make arbitrary fork code trusted. GitHub's cache
    scope is the additional boundary against a fork editing its own workflow.

    No test results, xcresult bundles, evidence, simulator state, DerivedData
    or final shared frameworks are cached. Every hit still builds, enumerates,
    packs this run's products and executes every planned test on fresh owned
    simulators. Build logs now hide shell-script environments and include
    verbose phase/Gradle output plus `-showBuildTimingSummary`; timing sums can
    overlap and are not a substitute for job wall clocks. Cache corruption is
    a failure to investigate, never a reason to accept old test evidence.
    Cache misses/eviction rebuild from pinned dependencies. Cache entry sizes
    and restore/save time must be checked on hosted runs: the repository's
    10 GB cache budget is shared with other lanes, and source-tree entries
    still consume one entry per saved tree. Gradle's
    [automatic cleanup](https://docs.gradle.org/8.14/userguide/directory_layout.html#dir:gradle_user_home:cache_cleanup)
    expires build-cache entries after seven days without access, with a
    default 24-hour cleanup interval. General user-home cleanup normally runs
    on daemon shutdown, or after the session with `--no-daemon` (already used
    by these Xcode phases). Gradle 8.14's `DirectoryBuildCache.close()` also
    closes its persistent cache, whose `DefaultCacheCoordinator.close()` checks
    for eligible cleanup; the build-scoped controller closes it at build end.
    A still-live daemon alone does not suppress that local-cache check, but
    the 24-hour interval can defer deletion. Age retention does not impose a
    size bound: before saving, a
    `du -sk` check skips empty/missing directories and those above 524288 KiB
    (512 MiB). This caps each newly saved build-cache directory without
    changing Gradle retention or deleting in-use entries. It does not cap
    total repository cache usage. Bump the namespace to invalidate a suspected
    bad cache.

    Baseline for this cache change: run 40166483245, head 198f7a11, attempts
    1/2. Build jobs were 680/1153 seconds: setup and runtime selection 16/43,
    simulator create+boot 80/148, build-for-testing 470/854, enumeration 84/80,
    packing+upload 10/9, and remaining cleanup/gaps 20/19 seconds. The existing
    `-quiet` logs do not expose separate package-resolution, Gradle/Kotlin/Native
    download/compile, Swift compile or linker intervals. The first Swift warning
    appeared 394/719 seconds after the build step started; the remaining
    76/135 seconds also mix compilation and linking. These are observable
    boundaries, not phase attribution. No download or cache saving is measured
    inside those opaque intervals, so per-phase savings remain hypotheses.
    Build logs contain 16 environment blocks (85 assignment lines) per attempt;
    downloaded measurement copies redact assignments before writing to disk.

    Attempt 1 unit shard 1 took 665 seconds: setup 16, simulator create+boot
    88, products/plan download+extract 6, test invocation 532, remainder 23.
    UI shard 1 took 1039 seconds: setup 11, simulator create+boot 87,
    download+extract 2, test invocation 917, remainder 22. Test invocations
    include additional test-runner startup; their durations are not case-time
    sums. The 24.7 MB products archive transfers in seconds, so changing its
    handoff cannot recover minutes. Simulator boot could overlap downloads,
    but only saves those few seconds here; no simulator-state reuse is added.

    Hosted run 40177765095 at dc26afff (Xcode 26.5) measured 14.3 minutes
    for build-for-testing cold and 14.9 minutes with exact hits on the original
    three caches. Its shared build phase took 579 seconds. Those measurements
    establish no hosted saving for the original cache paths.

    Local profiling on 2026-10-25 used Gradle 8.14 / Kotlin Gradle plugin
    2.2.20, Xcode 27.1 and Debug iphonesimulator arm64 build settings extracted
    with xcodebuild. A fresh worktree-local Gradle home and a private copy of
    the existing Konan distribution kept the global caches untouched. The
    first invocation took 1335.5 seconds; after deleting shared/build, it took
    228.5 seconds, with both Kotlin compilations and the static link FROM-CACHE.
    Swift export and its SwiftPM build re-executed: the pinned plugin disables
    caching for these experimental task types. Native static caches did not
    change. GRADLE_OPTS enabled the build cache even through an actual Xcode
    script phase; changing to --build-cache alone is not the fix.

    Fresh homes restoring only the original CI paths took 310.2 and 190.6
    seconds; the variation is why the first cold/warm difference is not a
    hosted saving forecast. Adding only the compiled DSL caches took 130.5
    seconds. Compared with the repeated baseline, settings evaluation fell
    from 45.7 to 18.5 seconds. The same three native tasks were FROM-CACHE;
    Swift export and its SwiftPM build still executed. Both comparisons began
    without project .gradle or shared/build. All 19 object members of the final
    library, exported symbols, Swift modules and headers matched; only archive
    metadata and four source-index files differed.

    A larger prototype retained generated-gradle-jars and transforms. It
    added about 1.25 GiB for only 23.3 seconds less than the small-cache run,
    before transfer costs, and is not retained. Keep the 4.3 MiB DSL addition
    based on the local settings-evaluation reduction; its hosted benefit is
    still a hypothesis, not an explanation for the native link miss.

    Follow-up: run 40177765095 attempt 2 restored all three exact keys, but
    Gradle still took 574 seconds with only two tasks FROM-CACHE (both Kotlin
    compilations). The native static link executed. The restored build-cache
    archive was 4,707,972 bytes. Those aggregate lines do not identify its
    entries or establish whether a link entry was ever stored. GitHub's cache
    metadata API also reports sizes, not archive contents. Do not infer a
    missing link entry from archive size alone; local archives differ with
    toolchain and debug information.

    The proposed run-dependent DerivedData explanation did not reproduce.
    Actual Xcode script invocations with output roots A, B, B, deleting
    shared/build each time and sharing one private Gradle cache, took
    137.6 / 111.4 / 123.2 seconds. All three cacheable tasks were FROM-CACHE:
    main compilation 22.63 / 23.89 / 24.13 seconds, bridge compilation
    0.48 / 0.20 / 0.34 seconds, link 1.73 / 1.20 / 1.16 seconds. Gradle's
    normalized input fingerprints and cache keys for those tasks matched
    across A/B/B. Only non-cacheable SwiftPM generation/merge input
    fingerprints varied; this does not establish their cause. Consequently the build's DerivedData path stays
    run-specific, along with every shard's artifact and evidence roots. The
    hosted miss's differing input remains unverified; local Xcode 27.1/JDK 21
    does not establish the behavior of hosted Xcode 26.5/JDK 17.

    The build job installs scripts/ci_gradle_timing.init.gradle only into its
    dedicated GRADLE_USER_HOME/init.d before build-for-testing. It records
    shared task paths, Gradle outcomes and wall seconds, plus configuration
    time from init-script evaluation through task-graph readiness (excluding
    wrapper/JVM startup). It uses public Gradle 8.14 TaskExecutionListener,
    TaskState, task-graph and build-finished APIs; configuration cache remains
    disabled, as in android/gradle.properties. Enabling configuration cache
    requires replacing these listeners. No timing file becomes a task input.
    The original Xcode product phases remain identical to dc26afff; Gradle's
    own actionable-task line supplies the counts.

    CI additionally enables Gradle info-level caching diagnostics, including
    normalized input fingerprints and stored/loaded entry keys. With
    -hideShellScriptEnvironment, the workflow preserves xcodebuild's exit
    status through tee and retains build.log, tasks.tsv and before/after
    build-cache METADATA inventories in the seven-day ios-build-gradle
    artifact, overwritten on a partial rerun. The compact TSV is printed even
    after build failure; partial rows remain diagnostic evidence, not tests.
    Inventories read only task identity, key, size, Gradle version and original
    execution time; they do not extract outputs. They distinguish an absent
    restored link entry from a stored entry looked up under a different key.
    Compare these artifacts on the next hosted runs before claiming a cause
    or a hosted speedup. Diagnostics add logging/I/O, not a measured saving.
    A local Xcode invocation of the unchanged product command and final CI
    logging settings took 143.4 seconds: configuration 24.96 seconds, main
    compilation 29.27, bridge 0.34 and link 1.33 seconds (all three FROM-CACHE).
    It recorded all fourteen shared outcomes. Separate task/configuration
    failure fixtures also retained FAILED rows with Gradle exit 1. Required checks, test selection and
    enumeration/execution evidence are unchanged.

    Under 25 minutes for the full lane needs a build below roughly 7 minutes
    with attempt 1's 17.3-minute longest test job, or below roughly 5.7 minutes
    with attempt 2's 19.1-minute job. No claim is made that this reaches it,
    or establishes the per-job p50 <15 / p90 <25 minute team budget.

    Wall-clock projections retain measured job overhead rather than halving
    whole jobs. In full run 40163436992, UI job overhead (job wall minus case
    sums) was 335.950/205.510 seconds, and unit overhead was 358.382 seconds.
    Conservatively using the slower UI overhead for the new longest UI shard,
    full is 15.2 min build + max(14.3 min unit, 17.0 min UI) + 0.1 min
    aggregate = about 32.3 min. Smoke run 40160114025's successful 14.6-minute
    unit job projects to 10.2 min after removing the 263.331 seconds assigned
    to the other shard: 13.7 min build + max(10.2 min unit, 7.3 min UI) +
    0.1 min aggregate = about 24.0 min. With the full run's higher unit
    overhead, smoke is about 28.1 min. These are single-run-based estimates;
    queue delays, host variance, new class-selection execution and per-shard
    startup/transfer remain unmeasured. The under-25-minute full target remains
    unmet, and even smoke needs hosted confirmation. Build alone is 13.7–15.2
    minutes in these runs and still exceeds the under-10-minute context budget.
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
  distinguishing commands. Trigger, head checkout, hosted runner and secret
  boundaries are guarded by the contract tests in `scripts/tests`.

  Recommended required status checks on main: `Determine changed paths`,
  `Android build`, `SwiftLint`, `Repository sanity`, `iOS simulator`, and
  `beid-lab-cli build and test`. Android, lint and lab CLI may legitimately
  be skipped by their changed-path classifier; a skipped required check counts
  as passing. The iOS aggregate instead reports success only after validating
  the same classifier bypass, never by accepting a skipped needed test job. Do not require the
  main-only delivery, trusted comparison or Release compilation jobs, nor the
  release-notes metadata warning. Branch protection is a separate operator
  change; this document does not claim it has been applied.

  Proposed operator settings after these workflows reach main: target the
  exact `main` branch (no wildcard), enable `Require merge queue`, choose
  merge method `merge` (merge commit), build concurrency `1`, Only merge
  non-failing pull requests enabled, status check timeout `120` minutes, and
  merge limits minimum/maximum `1` PR. Enable Allow merge commits in repository
  settings and retain all six required status checks above with GitHub Actions
  as their source. Queue build concurrency starts at one to limit concurrent
  full macOS suites; it does not serialize jobs within a run. These settings
  are a proposal and have not been changed by this work. See [GitHub's merge
  queue settings](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue).
- GitHub branch protection は approving review を merge 条件にしない。
  これは 2026-07-27 のオーナー判断による repository setting であり、
  上の KMP review gate を免除しない。KMP の independent review は作業上の
  gate、GitHub の approving review は merge button の設定で、別の条件である。

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
- **Versioning**: `MARKETING_VERSION` lives once in `ios/project.yml`
  (the project is xcodegen-generated — never hand-edit the `.xcodeproj`).
  Xcode Cloud builds use the Xcode Cloud run number.
  `CURRENT_PROJECT_VERSION` in `project.yml` remains an inert placeholder
  (`"1"`) — leave it, never bump it per build.
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
