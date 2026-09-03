---
name: beid-testflight
description: Handle beid TestFlight and Google Play internal-test delivery requests. Use for /testflight, "TestFlightに配信", "テストフライト配信", "Playに配信", "内部テストに配信", or requests to update beid What to Test notes.
---

# beid tester delivery

Use this repository-local contract instead of generic TestFlight assumptions.
Read `AGENTS.md`, `docs/xcode-cloud.md`, and `docs/google-play.md` first.
Refresh the target ref before describing current behavior. Do not push, trigger a
workflow, or mutate App Store Connect / Google Play unless the user explicitly
authorized that external action.

## Choose the note file

- Internal iOS + Android: edit `what_to_test.json`.
- iOS-only trigger: edit `what_to_test.ios.json`. The GHA iOS publisher still
  reads `what_to_test.json` first and uses the iOS file only when the common file
  is absent; never assume the triggering file is the published file.
- Android-only trigger: edit `what_to_test.android.json`. These files trigger
  the temporary Play lane; publishing their text as Play release notes is not
  automated.
- Release TestFlight: on `release/**`, edit `release_notes.json`. In beid this
  file is both release/App Store copy and the release build's What to Test source.
- Do not switch files solely because a generic skill or another repository uses
  a different convention.

Each file is a JSON array:

```json
[
  {"language": "en-US", "text": "Check this build's user-visible change."}
]
```

Use ASC locale identifiers. Follow the locale set in `AGENTS.md` (currently
`en-US` for tester notes), keep one non-empty entry per locale, and write only
what a tester can perform in this build. Use 1–3 plain sentences; omit issue
numbers, build numbers, internal file names, and accumulated history.

## Exact repository triggers

| Lane | Automatic push filter | Manual | Gate / runner | Concurrency |
| --- | --- | --- | --- | --- |
| Internal TestFlight | any branch AND `what_to_test.json` or `what_to_test.ios.json` changed | `workflow_dispatch` | `GHA_DELIVERY == on`; `[self-hosted, emi]` | `beid-ios-delivery`, no cancellation |
| Release TestFlight | `release/**` AND `release_notes.json` changed | `workflow_dispatch` | `GHA_DELIVERY == on`; `[self-hosted, emi]` | `beid-ios-delivery`, no cancellation |
| Internal Play | any branch AND `what_to_test.json` or `what_to_test.android.json` changed | `workflow_dispatch` | `GHA_DELIVERY == on`; `${{ vars.RUNS_ON_ANDROID || 'emi' }}` | `beid-android-delivery`, no cancellation |

Branch and path filters are conjunctive: both must match the same push. Xcode
Cloud is separate, configured in ASC, and remains the required iOS check even
while the temporary GHA delivery lane is active. Do not infer its live start
conditions from these YAML files.

The GHA iOS script prepares notes before archive/upload. After upload it waits
for the build uploaded during that run, takes the returned exact build ID, and
upserts every locale with `asc`. Missing/invalid source, preparation failure,
build lookup failure, or note upload failure makes the lane fail. A red note
step can coexist with an uploaded build; do not upload a duplicate just to retry
notes.

## Execute and verify

1. Confirm requested platform, branch, clean scope, and note file. Preserve the
   other locales and rewrite the selected note text for this build.
2. Validate with `python3 scripts/prepare_testflight_notes.py --source <file>
   --output-dir <temporary-dir>` and run relevant repository checks.
3. Commit/push only when authorized. Record the exact pushed SHA.
4. Find the matching GHA run with `gh run list --workflow <workflow-file>
   --branch <branch> --commit <sha>`, then inspect it with `gh run view <run-id>
   --json headSha,status,conclusion,url,jobs`. A skipped gate or absent run is not
   delivery.
5. For TestFlight, identify the exact build with `asc builds list --app
   org.levarac.beid --platform IOS --sort -uploadedDate --output json`; require
   `processingState=VALID`, confirm `asc builds test-notes list --build-id
   <build-id>` matches every intended locale/text, and use `asc builds groups
   list --build-id <build-id>` or ASC to confirm the intended tester group.
6. For Play, confirm the GHA run used the exact SHA, then verify in the Play
   Console/API that the `internal` track contains the new versionCode with
   completed status. GHA success alone is not store visibility.

Report separately: workflow triggered, build/upload succeeded, notes verified,
and tester-group/track visibility. Never collapse these into "delivered" when
one surface was not checked.

## Failure triage

- No run: check the exact branch + changed-path pair, `workflow_dispatch`, and
  whether the workflow exists on the relevant ref.
- Skipped job: check `GHA_DELIVERY`; do not turn it on without authorization.
- Early iOS failure: separate note validation, JDK/XcodeGen, credentials,
  keychain/profile, archive, upload, build processing, and note publication.
- Note publication failure after upload: reuse the logged exact build ID and
  retry `asc builds test-notes create`; do not rebuild by default.
- Release-only compile error (beid#348 class): a Debug build is irrelevant.
  Reproduce with the repository's Release device build using
  `CODE_SIGNING_ALLOWED=NO`; inspect Debug-only preview/helpers referenced from
  Release code, and require the informational macOS lane's Release step to pass.
- Play failure: distinguish credential/bootstrap, versionCode, signing, upload,
  and track-publication failures. Never generate a replacement upload key.

TODO until the separate internal-demo work lands: Release builds disable
`DemoEvent`; do not put demo-only steps in shipping tester notes or claim an App
Review/internal demo path exists. Re-check `ios/README.md` before removing this
warning.
