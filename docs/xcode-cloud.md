# Xcode Cloud → TestFlight

This document is the source of truth for beid's Xcode Cloud setup. It exists
because Xcode Cloud workflows are configured in the App Store Connect (ASC)
GUI, not in this repo, so the exact values used there need to live somewhere
reviewable. Modeled on
[umidori](https://github.com/ShiokazeHD/umidori)'s `docs/CICD.md`, trimmed to
beid's current scope (TestFlight only — no App Store submission automation
yet).

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
  numbers, no internal file or API names, no CI/CD jargon. This is the same
  contract umidori's `docs/CICD.md` documents; see that file if you want the
  fuller rationale (e.g. why build numbers/git-height never go in the text
  body).
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
  committed).
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
"What's New" text (like umidori's `add_new_version.rb`) is out of scope
until beid has real App Store submissions to automate.

## Workflow configuration Ken needs to enter in ASC

Xcode Cloud workflows are ASC-GUI-only (App Store Connect → beid → Xcode
Cloud → Workflows). Two workflows, both building the same scheme:

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

Version/build numbers: `project.yml` hardcodes
`MARKETING_VERSION: "1.0"` / `CURRENT_PROJECT_VERSION: "1"` — the same
values already used for the manually-uploaded 1.0(1) build in Organizer.
**Recommend Ken set ASC's Xcode Cloud "Build Number Source" to "Xcode
Cloud"** for the `Beid` product (ASC → Xcode Cloud → product settings) so
Xcode Cloud auto-increments the build number per successful build instead of
colliding with the manually-uploaded 1.0(1) or requiring a repo commit per
build. If that setting is left off, `CURRENT_PROJECT_VERSION: "1"` will
collide with the existing manual upload on the very first Xcode Cloud build
and get rejected by ASC — bump it in `project.yml` first in that case.

## First-time-only ASC step (not scriptable from here)

Connecting this GitHub repo to Xcode Cloud for the first time (the
repository grant/OAuth handshake) is interactive-only — there's no ASC API
for it. That has to happen before either workflow above can be created. See
the approval-package message for the exact click path.

## Local equivalent of what CI does

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
