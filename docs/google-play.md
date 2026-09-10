# Android delivery: GitHub Actions and Google Play

This document is the source of truth for beid's temporary Android delivery
lane. It records repository behavior, runner-local prerequisites, and the
manual activation steps that must be completed before API uploads can work.

## Current temporary status — 2026-08-28

`.github/workflows/internal-google-play.yml` builds a signed Android App
Bundle and uploads it to Google Play internal testing. It runs on pushes to
`main` that change `what_to_test.json` or `what_to_test.android.json`, and can
also be started manually. The job runs only when the repository variable
`GHA_ANDROID_DELIVERY` is exactly `on`, uses the self-hosted `emi` runner, and
keeps Android deliveries serialized without cancelling an in-progress upload.

**This is an Android-only switch, and that is the point.** It used to be
`GHA_DELIVERY`, which also gates the two temporary iOS lanes
(`internal-testflight.yml`, `release-testflight.yml`). Since
`internal-testflight.yml` triggers on a push to `main` that changes
`what_to_test.json` — the very file that also triggers this workflow — a single
shared variable made "turn on Android delivery" indistinguishable from "turn on
an iOS upload to App Store Connect from the same commit". The gates were split
in gh#401 so that arming Android arms Android only. Setting
`GHA_ANDROID_DELIVERY` has no effect on the iOS lanes, and setting
`GHA_DELIVERY` has no effect on this one.

The workflow is still not activated (`GHA_ANDROID_DELIVERY` remains
unset/`off`), but
the store-side bootstrap is done: the `org.levarac.beid` Play Console app
exists (same Levarac developer account as meissa), an upload keystore was
generated, and the mandatory first AAB upload was completed manually via the
Play Console UI on 2026-08-28 — built and signed locally (not on `emi`) using
the same steps `build-and-sign-android.sh` would run, since a one-off bootstrap
upload does not need the CI runner. The Play publishing service account is
`play-publisher@levarac.iam.gserviceaccount.com` (its own dedicated `levarac`
GCP project), granted "Release apps to testing tracks" scoped to just this
app. Remaining: either place the upload keystore and this service-account
JSON on `emi` at the paths below, or set the GitHub Secrets described in
"Hosted-runner support" — then flip `GHA_ANDROID_DELIVERY` to `on`.

The job's `runs-on` also now resolves through the repository variable
`RUNS_ON_ANDROID` (`${{ vars.RUNS_ON_ANDROID || 'emi' }}`), so the same
workflow file can run on either `emi` or a GitHub-hosted runner without
edits — see "Hosted-runner support" below. This mirrors the pattern
`ShiokazeHD/umidori` uses for its own Android delivery lane.

`what_to_test.json` and `what_to_test.android.json` are both the lane's trigger
**and** the text testers read. Since beid#503 a `Prepare Google Play release
notes` step runs `scripts/prepare_testflight_notes.py --platform android`,
which prefers `what_to_test.android.json` and falls back to
`what_to_test.json`, and writes one `whatsnew-<locale>` file per locale into
`$RUNNER_TEMP/whatsnew`. The upload step passes that directory as the
`whatsNewDirectory` input.

The 500-character clip is applied by that step rather than left to the upload
action, and this is not a stylistic choice. `r0adkll/upload-google-play` takes
the locale from the *filename* and sends the file's bytes verbatim, with no
length check of its own (read at the pinned commit
`e738b9dd8f2476ea806d921b64aacd24f34515a5`, `src/whatsnew.ts`). A longer note
is therefore rejected by the Play API at the point the edit is committed —
which is *after* the bundle has already been uploaded. Clipping earlier turns
that into a truncated note plus a log line naming both lengths. TestFlight's
own notes are deliberately **not** clipped at Play's limit; see
`docs/xcode-cloud.md`.

⚠️ **Nobody has yet seen this text in the Play Console.** The lane is still
inactive (`GHA_ANDROID_DELIVERY` unset/`off`), so what is verified today is the
wiring, by contract tests that execute the workflow step's own shell. The
tester-visible confirmation is dispatch#29's gate, not this document's claim.

## Repository pipeline

The workflow performs these steps:

1. `scripts/gha/check-play-delivery.sh` fails before the build if the
   runner-local environment file, service-account JSON, upload keystore,
   alias, or passwords are missing or unreadable.
2. `scripts/gha/build-and-sign-android.sh` selects the repository-approved
   JDK 17 through `scripts/resolve_kmp_java_home.sh`, builds
   `:app:bundleRelease`, and signs the resulting AAB with `jarsigner`.
3. `r0adkll/upload-google-play` is pinned to the immutable commit for v1.1.5
   and receives only the service-account file path. It uploads the signed AAB
   to the `internal` track with release status `completed`.

The source `android/app/build.gradle.kts` remains unchanged. During the CI
build, `scripts/gha/android-version-code.init.gradle` sets a temporary
versionCode to `1,000,000,000 + workflow run number × 10 + run attempt`. This
keeps manual bootstrap build `1` separate, gives reruns distinct codes, and
stays below Google Play's `2,100,000,000` limit. The generated manifest is
checked before signing so a failed injection cannot upload a duplicate code.

## Runner-local configuration

The `emi` runner has these non-secret path variables in
`~/actions-runner-beid/.env`:

```text
ANDROID_HOME=/Users/eiji/android-sdk
PLAY_CRED_DIR=/Users/eiji/.credentials/play
```

The Android SDK contains platform 36 and build-tools 36.0.0. The Play
credential directory and files must be owned by the runner user and kept out
of the repository. `$PLAY_CRED_DIR/env` must be mode 600 and define these five
variables — the credential file names are not fixed by any script and don't
need to match the example below; only the paths in this env file matter,
since `check-play-delivery.sh` and `build-and-sign-android.sh` read
everything through these variable names, never a hardcoded filename:

```text
PLAY_SERVICE_ACCOUNT_JSON=/Users/eiji/.credentials/play/<whatever-the-actual-file-is-named>.json
PLAY_KEYSTORE_PATH=/Users/eiji/.credentials/play/beid-upload.jks
PLAY_KEY_ALIAS=beid-upload
PLAY_KEYSTORE_PASSWORD=<runner-local value>
PLAY_KEY_PASSWORD=<runner-local value>
```

Do not print, commit, or send the password values or service-account JSON
through agmsg. `jarsigner` reads both passwords through environment-variable
references, so their values do not appear as command-line arguments.

## Hosted-runner support

The workflow can run on either `emi` or a GitHub-hosted runner. Which one a
given run uses is controlled by the repository variable `RUNS_ON_ANDROID`:
unset (the default) resolves to `emi`; setting it to `ubuntu-latest` switches
delivery to a GitHub-hosted runner instead. No workflow edit is needed to
switch — this follows the same `vars.RUNS_ON_* || <default>` pattern
`ShiokazeHD/umidori` uses for its own Android delivery workflow.

`emi`'s credential path is unchanged: it still reads the runner-local
`$PLAY_CRED_DIR/env` file described above. A GitHub-hosted runner is a fresh
VM on every run, so it has no such local state — instead, when
`runner.environment == 'github-hosted'`, the workflow decodes the same five
values from GitHub Secrets into a fresh, mode-600 env file under
`$RUNNER_TEMP`, then points `PLAY_CRED_DIR` at it. `check-play-delivery.sh`
and `build-and-sign-android.sh` run unchanged either way, since both only
care that `$PLAY_CRED_DIR/env` exists with the right five variable names.

Secrets required for the hosted-runner path (`gh secret set <name> --repo
thegreeting/beid`, run by Ken — these values should never pass through an
agent):

| Secret | Contents |
|---|---|
| `PLAY_KEYSTORE_B64` | `base64 -i beid-upload.jks \| pbcopy`, paste as the secret value |
| `PLAY_SERVICE_ACCOUNT_JSON_B64` | `base64 -i <service-account>.json \| pbcopy`, paste as the secret value |
| `PLAY_KEYSTORE_PASSWORD` | the upload keystore's store password, plain value |
| `PLAY_KEY_PASSWORD` | the `beid-upload` key's password, plain value |

The key alias is not sensitive, so it is a repository **variable** instead of
a secret: `PLAY_KEY_ALIAS`, default `beid-upload` if unset — only needs
setting if a different alias is ever used.

The hosted path also installs Android SDK platform 36 and build-tools 36.0.0
explicitly (via `sdkmanager`) rather than assuming a given runner image
already has them, and installs JDK 17 via `actions/setup-java`, exporting it
as `KMP_JAVA_HOME` — `resolve_kmp_java_home.sh`'s other detection branches are
all macOS-specific and cannot succeed on a Linux runner.

The licence-acceptance line in that step is written `(yes || true) | sdkmanager
--licenses`, not `yes | sdkmanager --licenses`: `sdkmanager` stops reading once
the licences are accepted, so `yes` dies of SIGPIPE and `pipefail` would
otherwise fail the step (gh#401). The subshell absorbs only `yes`'s death —
appending `|| true` to the whole pipeline instead would also hide a genuine
`sdkmanager` failure.

## Build position vs store number (git height)

Verified 2026-09-10.

The Android version row is `1.0.0 (1234+1000000091)`, which reads as
`{versionName} ({git height}+{versionCode})`. The two numbers have different
owners.

- **`versionCode` — the store number.** Assigned by the delivery workflow from
  the run (`1e9 + run×10 + attempt`), as described above. **gh#491 did not change
  how it is assigned**, and `versionCode = 1` in `android/app/build.gradle.kts`
  stays as the source-level placeholder.
- **git height — the build position.** `git rev-list --count HEAD`, computed by
  `internal-google-play.yml` and passed to Gradle as `-PgitHeight`, surfaced as
  `BuildConfig.GIT_HEIGHT`. It is a function of the built commit's ancestry, so
  **an Android build and an iOS build showing the same height were built from the
  same commit** — that is the only thing it is for. It identifies a commit, not a
  release.

**`fetch-depth: 0` on the checkout is load-bearing, not hygiene.** The default
depth-1 checkout is shallow, and on a shallow clone `git rev-list --count HEAD`
does not fail and does not return empty — it returns a **plausible smaller
number**, which would ship a wrong build position indistinguishable from a right
one. The height step therefore guards on
`git rev-parse --is-shallow-repository`, not on emptiness. iOS meets the same
requirement by deepening in `ci_post_clone.sh`.

`build-and-sign-android.sh` refuses to deliver when `BEID_GIT_HEIGHT` is unset
under CI rather than falling back to `local`; outside CI it omits the flag so a
developer build reads `local` from Gradle's own default. Never `0`, never empty.

## Ken-side activation list

These prerequisites were confirmed missing in the 2026-08-20 preflight; status
as of 2026-08-28:

1. ✅ Create the `org.levarac.beid` Play Console app — done, same Levarac
   developer account as meissa.
2. ✅ Generate and register an upload keystore — done (`beid-upload`, RSA
   4096). Also done: created a dedicated `play-publisher@levarac.iam.gserviceaccount.com`
   service account in its own `levarac` GCP project, enabled the Google Play
   Android Developer API on that project, and granted the service account
   "Release apps to testing tracks" scoped to just `org.levarac.beid`.
3. ⬜ Either place the upload keystore plus the service-account JSON under
   `/Users/eiji/.credentials/play` on `emi`, as the mode-600 `env` file
   described above, **or** set the four GitHub Secrets and one variable
   described in "Hosted-runner support" and switch `RUNS_ON_ANDROID` to
   `ubuntu-latest`. Not yet done either way — the bootstrap upload below was
   built and signed locally instead, so one of these two is still needed
   before CI can run.
4. ✅ Perform the first AAB upload manually in Play Console — done 2026-08-28,
   via the Play Console UI (a new app's first upload cannot be API-driven).

Item 3 still needs the interactive keystore-generation step, wherever the
keystore is generated (this bootstrap ran it locally rather than on `emi`,
since a one-off manual upload doesn't require the CI runner). It prompts for
the store and key passwords; do not add password flags or run it from
automation:

```bash
keytool -genkeypair \
  -keystore /Users/eiji/.credentials/play/beid-upload.jks \
  -storetype JKS \
  -alias beid-upload \
  -keyalg RSA \
  -keysize 4096 \
  -validity 10000 \
  -dname "CN=beid Android Upload, O=Levarac, C=JP"
```

If generating a fresh keystore on `emi` rather than copying the one already
used for the bootstrap upload, note that Google Play locks each app to the
upload-key certificate used on its first release — a second, different
keystore will be rejected on the next upload. Reuse the same keystore file
(copied to `emi`), not a newly generated one. Once the keystore and service-
account JSON are placed in the mode-600 `env` file on `emi`, this workflow
should be expected to go green.

## Disabling the temporary lane

Set the repository variable `GHA_ANDROID_DELIVERY` to `off`. The job-level gate
then skips this Android lane without deleting workflow files or runner
credentials. **It does not touch the two temporary iOS lanes** — those are
gated by `GHA_DELIVERY` and must be disabled separately. Before gh#401 one
variable did both, which is also why turning one on could not be done without
turning the other on. Credential removal and any permanent Android release
process are separate owner decisions.
