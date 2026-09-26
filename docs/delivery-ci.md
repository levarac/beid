# Delivery / CI contract (GitHub Actions + Xcode Cloud)

The platform delivery docs are `docs/xcode-cloud.md` for iOS and
`docs/google-play.md` for Android (canonical, each carries verification
dates). The contract every agent must know before touching delivery files:

## PR CI

All pull-request jobs use literal GitHub-hosted labels: `ubuntu-24.04-arm`
for classification/sanity, `ubuntu-24.04` for Android, and `macos-26` for
SwiftLint, iOS and the lab CLI. No pull-request workflow receives secrets, including same-repository PRs.
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

  - **`.github/workflows/pr-ci-lab-cli.yml`(beid#588、2026-09-17 追加)** —
    `tools/beid-lab-cli` (macOS の device-lab CLI) を
    `swift build -c release` + `swift test` で検査する lane。job 名は
    `beid-lab-cli build and test`。**required ではない**。GitHub-hosted `macos-26` 上で動き、**上の simulator lane とは別 workflow** である。理由は
    2 つあり、どちらも意図的:
    - この job は約 1 分で終わる。simulator lane の約 24 分に相乗りさせると、
      simulator test に影響し得ない変更のために #479 が意図的に狭めた
      trigger を広げることになる。**`pr-ci-ios-macos.yml` の `paths` に
      `tools/**` を足してはならない**
    - `synchronize` を**含む**。simulator lane が merge-candidate head を
      1 回測るのに対し、こちらは author が回しながら見る fast feedback で
      あり、`opened` だけでは 2 commit 目以降すべて stale になる。
      同じ理由で draft guard も無い (1 分は draft から取り上げる価値が無く、
      draft こそこの答えが欲しい時である)
    job 内の step は `scripts/ci_change_filter.py` の `labcli` 出力で gate
    される。`paths` が workflow を起動するかを決め、classifier が build する
    価値があるかを決める — つまり `tools/beid-lab-cli` の「この変更は build が
    要るか」の定義が YAML の glob と Python の規則に分裂せず 1 つで済む。
    classification が壊れたら全 lane true に倒れる (fail closed) ので、
    gate の故障は skip ではなく build になる。
    **`tools/beid-lab-cli/` は Android lane と SwiftLint lane を起動しない** —
    どの app target も link していない standalone SwiftPM package なので。
    ただし `Package.resolved` の basename 規則からの除外は
    `tools/beid-lab-cli/` だけに効く。`tools/` 配下の未分類の path は従来どおり
    fail closed のままである。

  **2026-09-02 以降、native iOS の build / test は 2 系統ある。** どちらも
  この subsection が正本で、他の文書は分担を複製せずここと実行定義を参照する。

  - **Xcode Cloud** — trusted Internal/Release delivery remains here. During
    public cutover the PR workflow stays paused until its fork credential
    boundary is verified. While paused, require executed hosted iOS evidence
    on the exact review head; a missing Xcode Cloud check is not success.
    Check current workflow state in ASC and exact-head results on GitHub.
    Branch protection and required contexts are separate operator settings;
    a clean merge state does not prove that an iOS check was required or ran.
  - **`.github/workflows/pr-ci-ios-macos.yml`(#301、2026-09-02 追加)** —
    GitHub-hosted `macos-26` 上の **informational-only** lane。job 名は
    `iOS simulator (GitHub-hosted macOS, informational)`。**required ではない**。
    **起動条件は次の 3 つだけであり、PR への push 毎ではない**
    (#479、2026-09-10 に変更): (1) `pull_request` の `opened` と
    `ready_for_review`、(2) `push` の `main`、(3) `workflow_dispatch`。
    (1)(2) には従来どおり `paths` filter がかかり、`ios/` `shared/`
    Android build 関連パスの変更でのみ起動する。`workflow_dispatch` に
    `paths` は効かないので、手動実行は常に走る。`synchronize` を外した理由は、
    この lane が 1 回あたり約 30 分かかりながら merge を gate せず、同じ head を
    当時 Xcode Cloud の `Beid | PR Build & Test | Test - iOS` が約 12 分で
    検証していたため。公開切替で PR workflow を停止する間は、後続 head の
    hosted iOS 検証を別途必須とする。2026-09-26 の公開準備で PR lane を GitHub-hosted に移した。
    以前の self-hosted 配信 runner との競合は現在の PR lane には当てはまらない。
    過去の計測と訂正は #479 および変更履歴に残る。
    **`opened` を入れてあるのは、`ready_for_review` が draft から上げた時に
    しか発火しないため。** issue #479 の本文は `ready_for_review` 単独を
    指定していたが、直近 25 本を timeline で数えると決着済み 22 本のうち
    13 本が `ReadyForReviewEvent` を持たず (ios 直撃のものを含む)、それだと
    PR の約 4 割しかカバーしない。非 draft で open された PR は open した
    瞬間から merge 候補の head を持つので、`opened` を足す方が issue の
    意図に沿う。**受け入れ基準 4 つは狭い方の集合でも満たせてしまうので、
    基準の充足を正しさの証明として扱わないこと。**
    **`opened` は draft PR でも発火するため、draft の除外は job 側の
    `if` が担う** (`github.event_name != 'pull_request' ||
    github.event.pull_request.draft == false`)。`paths` と `types` だけでは
    「draft でない」を表現できない。`event_name` の節は必須で、これを外すと
    `push` と `workflow_dispatch` では `github.event.pull_request` が存在せず
    式全体が false になり、main の計測が止まる。
    **PR で走ったことは、merge される head で走ったことを意味しない。**
    `synchronize` が trigger でない以上、非 draft の PR はこの lane を
    「open した時の head で 1 回」だけ走らせ、その後の push は head を
    変えたまま再実行しない (un-draft 後も同じ)。したがって
    **「PR でこの lane が緑だった」から merge 対象 commit の iOS 検証を
    導いてはならない**。merged 版を担保するのは `main` への push の方で、
    それは merge の後に走る。
    **観測上の注意**: draft PR を open した時は run 自体は記録され、job が
    `skipped` になる。draft PR への push は `synchronize` が trigger でない
    ため run 自体が記録されない。「起動しない」の証拠はこの 2 つで形が違う。
    **`skipped` の job が runner を占有する時間はゼロ秒**である (PR #486、
    2026-09-10 に初観測。job が `steps=0` で `started_at` と `completed_at` が
    同一)。上のコストモデルからすると、draft gate の価値はここにある —
    draft PR はこの lane の計算資源を消費しない。
    **`concurrency` は `github.ref` 単位で `cancel-in-progress: true` のまま**
    なので、main への連続 merge では前の main run が cancel される。merge 毎に
    run が「起動する」ことは保証されるが、**完走は保証されない**。
    起動条件そのものは `scripts/tests` 配下の contract test が固定しており、
    Repository sanity job の `python3 -m unittest discover -s scripts/tests -t .`
    で毎 PR 実行される (この subsection が件数もファイル名も書かないのは
    上と同じ理由 — 追加のたびに古くなるため)。
    Release device build (`CODE_SIGNING_ALLOWED=NO`) は別の
    `main-ios-release-build.yml` で main push 時に実行する。
    Xcode Cloud への依存を段階的に減らすための実績積みの段階であり、
    Xcode Cloud の設定・branch protection・他の workflow は変更していない。

  **`scripts/check_pr_ci_doc_drift.py` はこの 2 本目を検査していない。**
  同スクリプトは `.github/workflows/pr-ci.yml` のみを対象としており、
  **iOS lane が変わってもこの記述は緑のまま古くなる**。lane を触る変更は、
  検査に頼らずこの subsection を手で更新すること。#479 で
  `scripts/tests` に追加した contract test が固定するのは iOS lane の
  **起動条件だけ**であって、この subsection の散文ではない。起動条件以外は
  依然として手で追随させる必要がある。
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
