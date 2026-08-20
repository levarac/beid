# iOS delivery: GitHub Actions and Xcode Cloud

This document is the source of truth for beid's iOS delivery setup. It keeps
the retained Xcode Cloud configuration reviewable and records the temporary
GitHub Actions lane used while the Xcode Cloud budget is exhausted. Beid's
scope is TestFlight only; App Store submission automation is not included.

## Current temporary status — 2026-08-20

The Xcode Cloud workflows remain configured but are not the active delivery
path while their compute budget is exhausted. Two repository workflows provide
the temporary path:

| Workflow | Automatic trigger | Manual trigger |
|---|---|---|
| `.github/workflows/internal-testflight.yml` | Push to `main` changing `what_to_test.json` or `what_to_test.ios.json` | Yes |
| `.github/workflows/release-testflight.yml` | Push to `release/**` | Yes |

Both jobs run only when the repository variable `GHA_DELIVERY` is exactly
`on`. They share the fixed `beid-ios-delivery` concurrency group, do not cancel
an in-progress delivery, and run on the self-hosted `emi` runner. Set the
variable to `off` to silence both workflows when the Xcode Cloud budget
returns; no Xcode Cloud setting needs to be removed for this temporary lane.

`scripts/gha/build-and-upload-ios.sh` installs the XcodeGen version pinned by
`ios/ci_scripts/XCODEGEN_VERSION`, checks that generation leaves the committed
project clean, archives the Release scheme, and uploads it with
`xcodebuild -exportArchive`. The upload asks Apple to assign the next build
number. Authentication is runner-local: the script reads `$ASC_CRED_DIR/env`
and its referenced key file at runtime. Credentials must not be copied into
GitHub secrets, repository files, or logs.

This GitHub Actions upload does **not** currently publish TestFlight "What to
Test" notes. Xcode Cloud supplies those notes through
`ci_post_xcodebuild.sh`; an API-uploaded build needs a separate ASC API update
after processing. That notes update is a follow-up, not part of this temporary
upload lane.

## Two convention files, two audiences

| File | Repo location | Audience | Updated when |
|---|---|---|---|
| `what_to_test.json` | root | Internal testers | Any PR / feature branch / main push where you want a TestFlight build |
| `release_notes.json` | root | External testers / eventual App Store copy | `release/*` branch pushes |

Both are arrays of `{"language": "<ASC locale>", "text": "..."}`. Use ASC's
locale identifiers, not Xcode's String Catalog locale ids. Beid's current
settled locale set is `en-US` and `ja` (String Catalog uses `en` for English).
Both entries are required.

- **`what_to_test.json`**: what to check in *this* build. Rewrite it each
  time — don't accumulate history. 1–3 plain-language sentences, no PR/issue
  numbers, no internal file or API names, no CI/CD jargon. Rationale:
  tester-facing notes are product copy, not a changelog — build numbers,
  git height, and other machine-derived identifiers already travel in ASC
  metadata and never belong in the text body.
- **`release_notes.json`**: this version's marketing-style "what's new"
  copy. Rewrite completely per release, don't diff against the previous
  version.

Both `/testflight` (this repo's Claude Code skill) and hand edits follow this
same file-per-branch-type convention — see `~/.claude/skills/testflight/SKILL.md`
if you're driving this with that skill.

## What the repo-side scripts do

`ios/ci_scripts/` (Xcode Cloud's fixed hook location, `.sh` files must be
executable):

- **`ci_post_clone.sh`** — runs right after Xcode Cloud clones the repo.
  Installs the XcodeGen version pinned in `ci_scripts/XCODEGEN_VERSION`
  (downloaded straight from XcodeGen's GitHub release, not
  `brew install xcodegen`'s always-latest — an unannounced XcodeGen release
  could otherwise reformat/reorder the generated project and false-positive
  the drift guard with zero repo-side change), runs `xcodegen generate`,
  then fails the build if that left `Beid.xcodeproj` dirty
  (`git status --porcelain`, so new/untracked files inside the `.xcodeproj`
  bundle are caught too, not just changes to already-tracked ones). This
  exists because `project.yml` is this repo's source of truth (per
  `AGENTS.md`) and the generated `.xcodeproj` is committed for local-dev
  convenience — if someone edits `project.yml` without regenerating and
  committing the result, this step catches the drift immediately instead of
  silently building a stale/wrong project on Xcode Cloud.
  **Upgrading XcodeGen on purpose**: bump `ci_scripts/XCODEGEN_VERSION`,
  then run `cd ios && xcodegen generate` locally with a matching XcodeGen
  install and commit the resulting `Beid.xcodeproj` diff in the same PR —
  otherwise the guard fails on the very next Xcode Cloud run for the "right"
  reason (real drift between the pinned generator's output and what's
  committed). For the Kotlin Multiplatform shared module, this hook also
  installs Homebrew OpenJDK 17 when it is absent and logs the selected Java
  version. The resolver accepts only the fixed Homebrew JDK 17 path in Xcode
  Cloud; it never falls through to an ambient `JAVA_HOME` or JDK 25.
- **`ci_post_xcodebuild.sh`** — runs after the archive build. Picks
  `release_notes.json` when `$CI_BRANCH` matches `release/*`, otherwise
  `what_to_test.json`, and converts it (via
  `scripts/prepare_testflight_notes.py`) into
  `ios/TestFlight/WhatToTest.<locale>.txt`. Xcode Cloud picks these up
  automatically as the build's TestFlight "What to Test" notes — this is a
  documented Apple convention (a `TestFlight/` directory next to the
  `.xcodeproj`), not a custom upload step, so no ASC API credentials are
  needed for this part.

Nothing in these scripts calls the App Store Connect API or needs secrets —
scope is intentionally just "get a TestFlight build out with the right
notes." Pushing `release_notes.json` into an actual App Store version's
"What's New" text (via an ASC API script) is out of scope
until beid has real App Store submissions to automate.

The generated Beid target also has an always-run pre-build phase that invokes
Gradle's `:shared:embedSwiftExportForXcode` task before Swift compilation. It
recreates and copies the `BeidSharedKit` Swift module and static library into
the current Xcode build products directory, so a clean Xcode Cloud runner does
not depend on generated Swift artifacts being committed to the repository.

## Workflow configuration in ASC

Xcode Cloud workflow settings live in App Store Connect (App Store
Connect → beid → Xcode Cloud → Workflows), not in this repo. Most start
conditions (branch/PR patterns, files-and-folders rules) are also
editable via the App Store Connect API (`PATCH /v1/ciWorkflows/{id}`);
the TestFlight group post-action is the part that remains GUI-only (see
the beta-group section below). API quirk (verified 2026-08-02): `GET` on
a workflow omits `filesAndFoldersRule.matchers` — only the `mode` comes
back — but the `PATCH` response echoes the stored matchers, and the GUI
shows them; don't read an empty matcher list off a `GET` as "no filter".

Four workflows exist. The two delivery workflows, both building the same
scheme:

| Setting | Internal Build | Release Build |
|---|---|---|
| Start condition | Branch Changes — pattern `*` (or explicitly exclude `release/*` if ASC's pattern syntax needs it) | Branch Changes — pattern `release/*` |
| Files changed filter | `what_to_test.json` | `release_notes.json` |
| Xcode project/workspace | `ios/Beid.xcodeproj` | same |
| Scheme | `Beid` | same |
| Platform | iOS | same |
| Archive | Yes (Release configuration) | Yes (Release configuration) |
| Post-Action: TestFlight | Internal Testing group | Internal Testing group (flip to External once beid has passed beta app review, at Ken's discretion) |
| Environment variables | none required | none required |
| Post-Action script | none beyond the two `ci_scripts/` hooks (Xcode Cloud runs those automatically by filename/location) | same |

The other two workflows:

- **PR Build & Test** (id `a465d6ac-e3b5-4fe0-b586-db7285435990`) — the PR
  CI gate: build + test on pull requests targeting `main` (created
  2026-07-27; CI required, GitHub branch protection does not require an
  approving review). That repository setting does not waive the separate
  independent KMP review gate documented in `AGENTS.md`. Its start condition
  carries a files-and-folders rule
  intended to read `DO_NOT_START_IF_ALL_FILES_MATCH` with matchers
  `docs/` (directory), `.github/` (directory), and `md` (file extension),
  so that a PR whose every changed file matches one of those starts no
  macOS build. Background: before 2026-08-02 this workflow had no files
  rule at all, and a one-line docs PR burned a full macOS build+test.

  **Test destination — gh#129.** Verified 2026-08-06 against build 34's
  artifacts: the Test action's destination setting was "Recommended
  iPhones", which fans out to 4 simulators — iPhone 16 Pro, iPhone 16 Pro
  Max, iPhone 16, and iPhone SE (3rd generation) — each `test-without-building`
  run billed separately. Over the trailing 30 days (34 runs), ASC Usage
  showed ~23 compute-hours against ~8.7 actual summed action-hours, almost
  entirely attributable to this 4x fan-out (compounding with the test-speed
  issue tracked as gh#128). Judgment: the PR gate's suite is
  unit-test-dominated — `BeidUITests`' `BeidIPadLayoutTests` is the only
  device-shape-sensitive UI test in the repo, and it isn't why the
  4-device matrix existed — so the PR gate does not benefit from 4-device
  coverage. A device matrix, if ever needed for layout regression
  coverage, belongs in a separate nightly or pre-release workflow, not
  every PR push. Per gh#129's 2026-08-06 comment: with owner approval, the
  `testDestinations` setting was changed via API `PATCH` from "Recommended
  iPhones" to a single `iPhone 16 Pro` (default runtime) on 2026-08-07
  07:0x JST, confirmed by an immediate follow-up `GET`, with a full backup
  of the prior setting taken (rollback-capable). **Open**: confirming on a
  subsequent real PR run's artifacts that "on 4 destinations" no longer
  appears has not yet been done — this doc note records the judgment and
  the change, not that confirmation.

  **⚠️ 2026-08-03 の「docs ファイルが diff に居る時だけ起動する」説は、
  2026-08-04 に #93 のコメントで反証済み (このブロックは 2026-08-06 訂正)。**

  経緯: 上の表 (#92 が code-only でスキップ) から「docs/.github/.md の
  存在がトリガー」という逆転説が立ったが、docs ファイルを含む #94 が
  起動せずその説は死に、続いて #94 への**空 commit** (ファイル変更ゼロ)
  で build が起動した。つまり **diff の内容はトリガーと無関係**。

  現時点で最も支持される記述: **PR 作成直後の初回評価が、時々、無言で
  行われない**。その後に何かを push すれば (内容不問、空 commit で足りる)
  評価は回復する。トリガー条件そのものは repo 側からは説明が付かず、
  ASC 側の調査が必要 (#93 が open で追跡中)。

  実害の形はこう読む: 起動しなかった PR は **失敗でも pending でもなく、
  チェックが「存在しない」**。Ubuntu 系の checks だけが green のままでも merge 可能に
  見える。したがってレビュー/マージ時の確認は「Test - iOS が green か」
  ではなく **「Test - iOS が exact head に存在し、かつ green か」**。
  不在なら空 commit を push して再評価させる。

  Xcode Cloud は metered であり、open PR の branch への push は実費の
  ある build を起動し得る。反復は local build で行い、push はまとめる。
  この存在確認は workflow が自動起動する現在の形に対する規則である。
  将来 manual trigger に切り替えた場合、trigger 前の不在は正常なので、
  意図して起動した run が exact head を対象にし、green になったことを
  evidence とする。

  This directly contradicts the "fails open" claim this section used to
  make (that a misconfiguration "can waste compute but never silently skip
  CI for a code change"). That claim was an assumption about ASC's matcher
  semantics, never tested in the code-only direction. It has now been
  tested and it is false. Per `AGENTS.md`, ASC is the source of truth over
  this doc — the fix belongs in the ASC GUI, not here.

  **Until it is fixed**, a code-only PR's green Ubuntu checks prove only the
  hosted jobs named in the repository's authoritative
  [PR CI contract](../AGENTS.md#pr-ci). They do not prove that anything was
  built or tested on macOS. Tracked as gh#93.
- **Default** — the leftover initial-setup workflow. Disable-or-delete
  candidate; kept only until the maintainer rules on it.

  **Corrected 2026-08-20: "branch `main`, no files rule" was wrong.**
  Observation over 14 consecutive `main` commits contradicts it. `Default`
  fired on **exactly** the 4 that changed `what_to_test.json`
  (`870baec`, `ae81bf5`, `4f51fab`, `bbd0b76`) and on **none** of the 10
  that did not (`5398604`, `1af54eb`, `99cb85b`, `a63fc1e`, `af7fe69`,
  `b50fd1d`, `d506568`, `51cbb0e`, `eadbf2b`, `13f9d69`) — checked via the
  commit-statuses API, which is where Xcode Cloud reports, not
  check-runs. Internal Build fired on exactly the same 4 and no others.

  So `Default` behaves as though it carries the same
  `what_to_test.json` files filter as Internal Build, and duplicates that
  workflow rather than firing on every `main` push. Its waste is one extra
  archive **per TestFlight delivery**, not per push — a materially smaller
  number than the earlier wording implied, and one that was cited as a
  compute-budget factor before anyone measured it.

  The settings themselves live in the ASC GUI and were not re-read for this
  correction; only the observed firing behaviour was. Treat this as a
  last-checked observation, not a settings audit — and per this document's
  own rule, when ASC and this file disagree, ASC wins.

  **Method note, because this is the second time this document has been
  wrong about a start condition** (see the 2026-08-04 reversal of the
  "docs files in the diff are the trigger" theory): a start-condition claim
  is only worth what the observation behind it is worth. Correlate firings
  against the actual diffs across enough commits to distinguish the
  hypothesis from coincidence before writing it down as fact.

Version/build numbers: `project.yml` hardcodes
`MARKETING_VERSION: "1.0"` / `CURRENT_PROJECT_VERSION: "1"`.
**Verified 2026-07-23**: ASC's "Build Number Source: Xcode Cloud" is in
effect — delivered build numbers equal the Xcode Cloud run numbers
(builds 3/7/8/9 = runs 3/7/8/9), so the repo's
`CURRENT_PROJECT_VERSION` is inert and must not be bumped per build. The
temporary GitHub Actions lane instead sets
`manageAppVersionAndBuildNumber: true` during export, so Apple assigns its
next build number without changing `project.yml`.
`MARKETING_VERSION` remains the single version knob, in `project.yml`
only.

## First-time-only ASC step (not scriptable from here)

Connecting this GitHub repo to Xcode Cloud for the first time (the
repository grant/OAuth handshake) is interactive-only — there's no ASC API
for it. That has to happen before either workflow above can be created. See
the approval-package message for the exact click path.

## TestFlight beta-group auto-linking — resolved history

**Status: RESOLVED 2026-07-23.** Root cause: the workflows were created via
the ASC API, which cannot express the GUI-only "TestFlight Internal
Testing → group selection" post-action — so no group assignment existed at
all (the workflow's API view shows only `ARCHIVE` +
`buildDistributionAudience: INTERNAL_ONLY`). Fix: the Dev-group delivery
was added to the Internal Build workflow **in the ASC GUI** on 2026-07-23;
builds 8 and 9 then auto-delivered to Dev with no manual `add-groups`
(verified). Diagnosis note for the future: check membership via
`GET /v1/betaGroups/{id}/builds` — the reverse direction
(`GET /v1/builds/{id}/betaGroups`) reads empty for internal groups even
when linked, and misled the first diagnosis. Historical investigation
trail follows because the `ci_post_xcodebuild` timing constraint remains
true. It describes the state before the GUI fix and is not a current action
list.

Before the GUI fix, builds did not auto-link to the "Dev" internal beta group
(`5422706d-fbf9-41dc-9f6e-60e6e6fda8e4`, app `6789376188`) despite that group
having `hasAccessToAllBuilds=true`. Build 3 was linked as a one-off manual
workaround via `asc builds add-groups`; later builds proved that workaround
was unnecessary once the workflow's GUI post-action was configured.

### Historical constraint: why the fix could not live in `ci_post_xcodebuild.sh`

The obvious-looking fix — add a step to `ci_post_xcodebuild.sh` that calls
the App Store Connect API to link the just-archived build to the Dev group —
does not work, structurally, regardless of implementation (a direct API
poll and the `asc` CLI both fail the same way). Xcode Cloud's workflow action
order is:

```
... → xcodebuild archive → ci_post_xcodebuild.sh → TestFlight post-action (Apple-run upload + processing)
```

`ci_post_xcodebuild.sh` runs **before** Xcode Cloud's own TestFlight
post-action uploads the archive to App Store Connect. The workflow does not
begin that upload until the hook script exits. So at the moment
`ci_post_xcodebuild.sh` runs, the build does not yet exist as an ASC `Build`
resource — there is no build ID to poll for: the very thing a poll would
wait for cannot be created until the polling script has already finished. A
bounded or unbounded poll
inside this hook is a deadlock by construction, not a slow/expensive
tradeoff — no timeout tuning fixes it. At the time, there was no other
repo-scriptable Xcode Cloud hook that ran *after* the TestFlight post-action
completed.

(Confirmed against Apple's
[Configuring your Xcode Cloud workflow's actions](https://developer.apple.com/documentation/xcode/configuring-your-xcode-cloud-workflow-s-actions)
and cross-checked against community documentation of the same ordering,
e.g. [polpiella.dev — Deploying beta versions via Xcode Cloud](https://www.polpiella.dev/how-to-deploy-beta-versions-of-your-app-to-testflight-and-appcenter-with-xcode-cloud).)

### Historical diagnosis (using the correct relationship direction)

During the investigation, these were the useful read-only checks. The third
query deliberately reads builds from the group. Do not replace it with the
reverse `/v1/builds/{id}/betaGroups` relationship, which is empty for
internal groups even when delivery is working.

```sh
# This read-only ASC block may run from any directory.
# 1. Confirm the Dev group's actual hasAccessToAllBuilds state and app linkage
asc api get "/v1/betaGroups/5422706d-fbf9-41dc-9f6e-60e6e6fda8e4?include=app"
# or raw REST if you don't have `asc`'s api passthrough:
# GET https://api.appstoreconnect.apple.com/v1/betaGroups/5422706d-fbf9-41dc-9f6e-60e6e6fda8e4?include=app

# 2. List recent VALID (fully processed) builds for the app
asc api get "/v1/builds?filter[app]=6789376188&filter[processingState]=VALID&sort=-uploadedDate&limit=10"

# 3. List the builds actually available to the Dev group, then compare IDs
asc api get "/v1/betaGroups/5422706d-fbf9-41dc-9f6e-60e6e6fda8e4/builds"
```

What these checks were intended to distinguish:
- If `hasAccessToAllBuilds` read `true` and recent VALID build IDs appeared in
  the group's build list, no explicit linking automation was needed.
- If `hasAccessToAllBuilds` read `true` but recent VALID build IDs stayed
  absent from the group's build list after processing, that indicated an
  ASC-side inconsistency rather than something this repo could repair in the
  Xcode Cloud hook.
- **409 risk**: the `POST /v1/betaGroups/{id}/relationships/builds`
  endpoint (explicit build-to-group linking) is designed for curated
  (non-all-access) groups. If `hasAccessToAllBuilds` is genuinely `true` for
  the Dev group, ASC may reject explicit linking calls as a conflict. Don't
  assume "add an explicit link step" is the fix without first confirming
  the group's real state and whether the API will even accept the call.

### Historical rejected alternative: an explicit-link reconciler

Before the GUI root cause was found, an out-of-band reconciler was proposed
as the only viable scripted shape. It was never implemented and is not a
current recommendation. If a future workflow loses its GUI post-action,
restore that setting first rather than building this machinery.

The archived proposal was:

- A new GitHub Actions workflow (for example,
  `.github/workflows/testflight-beta-link.yml`) would have run on a schedule
  and by manual dispatch.
- Each run would have listed recent VALID builds, compared them with
  `GET /v1/betaGroups/{id}/builds`, and explicitly linked missing IDs. That
  reconciliation shape would have been self-healing across ASC outages or
  long processing delays.
- A per-build 409 would have been logged without failing the entire run, so a
  `hasAccessToAllBuilds` semantics mismatch stayed visible.
- Testers would have seen a new build after Apple's processing time plus the
  schedule interval. Moving the poll back into `ci_post_xcodebuild.sh` could
  not have shortened that delay.

**Historical prerequisite:** this proposal would have required a narrowly
scoped ASC API key in GitHub Actions. Because the GUI post-action fixed the
root cause, that additional automation and credential are not required by
the current workflow.

### Local equivalent of what CI does

```sh
# Start in the repository root.
cd ios
xcodegen --version                    # should match ci_scripts/XCODEGEN_VERSION
xcodegen generate                     # must leave Beid.xcodeproj clean (git status --porcelain)
git status --porcelain -- Beid.xcodeproj
xcrun simctl list devices available
xcodebuild -project Beid.xcodeproj -scheme Beid \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' build
cd ..
python3 scripts/prepare_testflight_notes.py \
  --source what_to_test.json --output-dir /tmp/testflight-notes-check
cat /tmp/testflight-notes-check/*.txt
```
