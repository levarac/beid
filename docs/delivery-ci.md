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
  `main` への push で、GitHub-hosted Linux/macOS 上に次の gate を実行する。
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
    builds. This standalone package has its own lane so its result does not
    wait for the simulator suite.

  - **`.github/workflows/pr-ci-ios-macos.yml`** — `iOS simulator` is the
    hosted iOS PR gate. `pull_request` includes `opened`, `synchronize`,
    `reopened`, and `ready_for_review`, with no path filter or draft guard.
    Thus every PR creates the `iOS simulator` context for branch protection.
    A `Classify paths for iOS lane` job runs the same collection step and
    `scripts/ci_change_filter.py` as `Determine changed paths`; the lane has a
    job-level `if:` and runs when the classifier reports `android`, `lint` or
    `error` (Android changes can affect the shared KMP build). A
    documentation-only PR therefore reports `iOS simulator` as skipped, which
    GitHub treats as passing for a required check, and a failed classification
    job runs the lane. The lane uses `!cancelled()` rather than `always()` so a
    superseded run does not start a macOS job. Main pushes retain their
    iOS/build-input path filter and always run the lane, and
    `workflow_dispatch` supports deliberate verification and is never skipped.
    The two classification jobs have their own names, distinct from
    `Determine changed paths`, because required contexts are keyed by job name;
    do not add them to the required list.
    All PR build lanes check out `github.event.pull_request.head.sha`
    explicitly; push and manual events check out `github.sha`.

    The standard `macos-26` image uses `/Applications/Xcode_26.5.app` and
    requires the iOS 26.5 runtime. `scripts/ci_simulator.py` creates a new
    simulator for each job and returns its UDID; only that device is booted,
    tested and deleted, even on failure. Build-for-testing and
    test-without-building run the complete Beid scheme (`BeidTests` and
    `BeidUITests`) with `SWIFT_OPTIMIZATION_LEVEL=-O`. The structured xcresult
    summary must contain nonzero tests, consistent counts and a passing result.
    Superseded runs are cancelled; require a completed passing run for the
    exact current PR head before merge.

    Unsigned Release device compilation (`CODE_SIGNING_ALLOWED=NO`) remains
    in `main-ios-release-build.yml` on main push/manual dispatch, also using
    Xcode 26.5. It is not a PR status check or a signing/delivery lane.

  - **Xcode Cloud** — keep `PR Build & Test` paused. Hosted iOS now performs
    the build plus unit/UI test role on every PR head without signing secrets;
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
  `beid-lab-cli build and test`. Android, lint, iOS and lab CLI may
  legitimately be skipped by their changed-path classifier (all four on a
  documentation-only PR); a skipped required check counts as passing. Do not require the
  main-only delivery, trusted comparison or Release compilation jobs, nor the
  release-notes metadata warning. Branch protection is a separate operator
  change; this document does not claim it has been applied.
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
