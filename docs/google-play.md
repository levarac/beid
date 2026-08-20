# Android delivery: GitHub Actions and Google Play

This document is the source of truth for beid's temporary Android delivery
lane. It records repository behavior, runner-local prerequisites, and the
manual activation steps that must be completed before API uploads can work.

## Current temporary status — 2026-08-20

`.github/workflows/internal-google-play.yml` builds a signed Android App
Bundle and uploads it to Google Play internal testing. It runs on pushes to
`main` that change `what_to_test.json` or `what_to_test.android.json`, and can
also be started manually. The job runs only when the repository variable
`GHA_DELIVERY` is exactly `on`, uses the self-hosted `emi` runner, and keeps
Android deliveries serialized without cancelling an in-progress upload.

The workflow is authored but activation is blocked on Ken. Live Play Console
inspection on 2026-08-20 found no app record for `org.levarac.beid`, and the
runner does not yet have the upload key or Play service-account JSON. A new
Play app's first AAB upload must be completed manually in Play Console before
the Android Publisher API can upload subsequent builds.

`what_to_test.json` and `what_to_test.android.json` are trigger inputs only in
this temporary lane. Publishing their text as localized Google Play release
notes is not automated in this slice.

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
of the repository. `$PLAY_CRED_DIR/env` must be mode 600 and define:

```text
PLAY_SERVICE_ACCOUNT_JSON=/Users/eiji/.credentials/play/beid-play-service-account.json
PLAY_KEYSTORE_PATH=/Users/eiji/.credentials/play/beid-upload.jks
PLAY_KEY_ALIAS=beid-upload
PLAY_KEYSTORE_PASSWORD=<runner-local value>
PLAY_KEY_PASSWORD=<runner-local value>
```

Do not print, commit, or send the password values or service-account JSON
through agmsg. `jarsigner` reads both passwords through environment-variable
references, so their values do not appear as command-line arguments.

## Ken-side activation list

These prerequisites were confirmed missing in the 2026-08-20 preflight:

1. Create the `org.levarac.beid` Play Console app.
2. Generate and register an upload keystore.
3. Place the keystore plus service-account JSON under
   `/Users/eiji/.credentials/play`.
4. Perform the first AAB upload manually in Play Console because a new app
   first upload cannot be API-driven.

Ken should generate the upload key interactively on `emi` with this proposed
command. It prompts for the store and key passwords; do not add password flags
or run it from automation:

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

After creating the Play app, complete the first manual internal-testing
release with this upload key, register the upload certificate in Play Console
if requested, enable the Google Play Android Developer API, and grant the
service account permission to release `org.levarac.beid`. Then place the files
and mode-600 `env` file on `emi`. Only after those steps should this workflow
be expected to go green.

## Disabling the temporary lane

Set the repository variable `GHA_DELIVERY` to `off`. The job-level gate then
skips this Android lane and both temporary iOS lanes without deleting workflow
files or runner credentials. Credential removal and any permanent Android
release process are separate owner decisions.
