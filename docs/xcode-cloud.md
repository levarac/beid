# Xcode Cloud → TestFlight

This document is the source of truth for beid's Xcode Cloud setup. It exists
because Xcode Cloud workflows are configured in the App Store Connect (ASC)
GUI, not in this repo, so the exact values used there need to live somewhere
reviewable. Modeled on the delivery documentation of a sister project,
trimmed to beid's current scope (TestFlight only — no App Store submission
automation yet).

## Two convention files, two audiences

| File | Repo location | Audience | Updated when |
|---|---|---|---|
| `what_to_test.json` | root | Internal testers | Any PR / feature branch / main push where you want a TestFlight build |
| `release_notes.json` | root | External testers / eventual App Store copy | `release/*` branch pushes |

Both are arrays of `{"language": "<ASC locale>", "text": "..."}`. Use ASC's
locale identifiers, not Xcode's String Catalog locale ids — for beid's
current 5-locale set that's `en-US`, `ja`, `zh-Hans`, `es-ES`, `fr-FR` (String
Catalog uses `en`/`es`/`fr`, ASC wants the region-qualified form). `ja` and
`en-US` are the required minimum; keep the others in sync when practical.

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
  2026-07-27; CI required, reviews optional per the maintainer decision in
  `AGENTS.md`). Its start condition carries a files-and-folders rule
  intended to read `DO_NOT_START_IF_ALL_FILES_MATCH` with matchers
  `docs/` (directory), `.github/` (directory), and `md` (file extension),
  so that a PR whose every changed file matches one of those starts no
  macOS build. Background: before 2026-08-02 this workflow had no files
  rule at all, and a one-line docs PR burned a full macOS build+test.

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
  チェックが「存在しない」**。Ubuntu 系 3 つの green だけで merge 可能に
  見える。したがってレビュー/マージ時の確認は「Test - iOS が green か」
  ではなく **「Test - iOS が exact head に存在し、かつ green か」**。
  不在なら空 commit を push して再評価させる。

  This directly contradicts the "fails open" claim this section used to
  make (that a misconfiguration "can waste compute but never silently skip
  CI for a code change"). That claim was an assumption about ASC's matcher
  semantics, never tested in the code-only direction. It has now been
  tested and it is false. Per `AGENTS.md`, ASC is the source of truth over
  this doc — the fix belongs in the ASC GUI, not here.

  **Until it is fixed**, a code-only PR's green checks mean only that
  Ubuntu lint and sanity passed. Nothing was built or tested on macOS.
  Tracked as gh#93.
- **Default** — the leftover initial-setup workflow (branch `main`, no
  files rule). Disable-or-delete candidate; kept only until the
  maintainer rules on it.

Version/build numbers: `project.yml` hardcodes
`MARKETING_VERSION: "1.0"` / `CURRENT_PROJECT_VERSION: "1"`.
**Verified 2026-07-23**: ASC's "Build Number Source: Xcode Cloud" is in
effect — delivered build numbers equal the Xcode Cloud run numbers
(builds 3/7/8/9 = runs 3/7/8/9), so the repo's
`CURRENT_PROJECT_VERSION` is inert and must not be bumped per build.
`MARKETING_VERSION` remains the single version knob, in `project.yml`
only.

## First-time-only ASC step (not scriptable from here)

Connecting this GitHub repo to Xcode Cloud for the first time (the
repository grant/OAuth handshake) is interactive-only — there's no ASC API
for it. That has to happen before either workflow above can be created. See
the approval-package message for the exact click path.

## TestFlight beta-group auto-linking — investigation

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
trail follows (kept for the ci_post_xcodebuild timing analysis, which
remains true).

Builds are not auto-linking to the "Dev" internal beta group
(`5422706d-fbf9-41dc-9f6e-60e6e6fda8e4`, app `6789376188`) despite that group
having `hasAccessToAllBuilds=true`, which per Apple's model should make every
processed build available to it with no explicit per-build action. Build 3
was linked as a one-off manual workaround via `asc builds add-groups`, which
is not durable — this section is the investigation trail for a real fix.

### Why the fix can't live in `ci_post_xcodebuild.sh`

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
tradeoff — no timeout tuning fixes it. There is currently no other
repo-scriptable Xcode Cloud hook that runs *after* the TestFlight
post-action completes.

(Confirmed against Apple's
[Configuring your Xcode Cloud workflow's actions](https://developer.apple.com/documentation/xcode/configuring-your-xcode-cloud-workflow-s-actions)
and cross-checked against community documentation of the same ordering,
e.g. [polpiella.dev — Deploying beta versions via Xcode Cloud](https://www.polpiella.dev/how-to-deploy-beta-versions-of-your-app-to-testflight-and-appcenter-with-xcode-cloud).)

### Diagnose before building anything

Before building a fix, confirm there is actually a bug to fix, and that
explicit build-group linking is even the right shape. Run this first
(needs an ASC API key with App Manager or Developer role; the `asc` CLI
config on this machine currently points at the Levarac key `76FJ56SHXV`):

```sh
# 1. Confirm the Dev group's actual hasAccessToAllBuilds state and app linkage
asc api get "/v1/betaGroups/5422706d-fbf9-41dc-9f6e-60e6e6fda8e4?include=app"
# or raw REST if you don't have `asc`'s api passthrough:
# GET https://api.appstoreconnect.apple.com/v1/betaGroups/5422706d-fbf9-41dc-9f6e-60e6e6fda8e4?include=app

# 2. List recent VALID (fully processed) builds for the app
asc api get "/v1/builds?filter[app]=6789376188&filter[processingState]=VALID&sort=-uploadedDate&limit=10"

# 3. For each recent VALID build, check whether it's actually available to the Dev group
asc api get "/v1/builds/<BUILD_ID>/betaGroups"
```

What this should tell us:
- If `hasAccessToAllBuilds` reads `true` and recent VALID builds already show
  up under `betaGroups` for that build without ever having been explicitly
  linked, then build 3's failure to auto-link may have been a one-off
  (e.g. still `PROCESSING` at the time it was checked, or checked before
  ASC's internal propagation caught up) rather than a systemic bug — in
  which case no automation is needed at all, just patience or a documented
  "processing can take up to ~60 minutes" expectation.
- If `hasAccessToAllBuilds` is `true` but recent VALID builds are still not
  showing as available to the group, that's a real ASC-side inconsistency
  worth a support case, separate from anything this repo can script around.
- **409 risk**: the `POST /v1/betaGroups/{id}/relationships/builds`
  endpoint (explicit build-to-group linking) is designed for curated
  (non-all-access) groups. If `hasAccessToAllBuilds` is genuinely `true` for
  the Dev group, ASC may reject explicit linking calls as a conflict. Don't
  assume "add an explicit link step" is the fix without first confirming
  the group's real state and whether the API will even accept the call.

### If diagnosis confirms explicit linking is genuinely needed

Do not attempt this in `ci_post_xcodebuild.sh` (see above). The durable
shape is an out-of-band, idempotent reconciler outside Xcode Cloud's build
machine entirely — proposed, not implemented:

- A new GitHub Actions workflow (e.g. `.github/workflows/testflight-beta-link.yml`)
  triggered on a `schedule` cron (e.g. every 15 minutes) plus
  `workflow_dispatch` for manual runs.
- Each run: `GET /v1/builds?filter[app]=6789376188&filter[processingState]=VALID`
  for a recent window, diff against builds already linked to the Dev group,
  and `POST .../relationships/builds` for any that are missing. Reconciling
  the full unlinked set (rather than tracking "the one build from this CI
  run") avoids needing to hand a build ID from Xcode Cloud to GitHub Actions,
  and is self-healing across ASC outages or long processing delays.
- Log-and-continue on a per-build 409 rather than failing the whole run, so
  a `hasAccessToAllBuilds` semantics mismatch shows up as a visible log line
  instead of a red workflow.
- Testers see a new build up to `(processing time + cron interval)` after
  archive — that latency is inherent to Apple's own processing pipeline,
  not something this reconciler can shorten; don't "fix" it later by moving
  the poll back into `ci_post_xcodebuild.sh`.

**Ken action needed if this path is taken:** a new ASC API key scoped to
Xcode-Cloud/TestFlight read + beta-group-write only (not the broader Levarac
key already in use), added as GitHub Actions repository secrets — see the PR
description for the exact key name, permission scope, and where to paste it.

### Local equivalent of what CI does

```sh
cd ios
xcodegen --version                    # should match ci_scripts/XCODEGEN_VERSION
xcodegen generate                     # must leave Beid.xcodeproj clean (git status --porcelain)
git status --porcelain -- Beid.xcodeproj
xcodebuild -project Beid.xcodeproj -scheme Beid \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
cd ..
python3 scripts/prepare_testflight_notes.py \
  --source what_to_test.json --output-dir /tmp/testflight-notes-check
cat /tmp/testflight-notes-check/*.txt
```
