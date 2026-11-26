# Read-only release supplier evidence (Beid #462)

This procedure exports only the existing Parallax manifest fragment at main
`239d1b2a92bebd0bcf3520801de80c23a7491be7`:

```json
{
  "builds": {
    "ios": "1.1.0 (1042)",
    "android": "1.1.0 (1042)"
  },
  "barnard": {"tag": "v…", "commit": "…"}
}
```

The build strings use the packaged version followed by the build number in
parentheses. The example is synthetic. The command reads source pins from the
requested Git commit and supplied immutable evidence. It creates a new output
file atomically and refuses an existing path. The evidence inputs are retained
separately from the public export for each platform's concrete Barnard identity,
source association, receipt locator and receipt/package SHA-256.

## Exact accepted evidence formats

The iOS JSON format name is `beid-ios-approved-metadata-v1`. It contains:

* `build.version` and string `build.build`, read from approved packaged-build
  metadata rather than source defaults;
* packaged `barnard.tag` and 40-hex `barnard.commit`;
* `provenance.sourceCommit`, which associates that build with the candidate;
* `receipt.kind` (`public-url` or `offline-package`), `receipt.locator`, and
  lowercase 64-hex `receipt.sha256`.

The tool reuses the repository's Barnard `exactVersion` reader and independently
reads the `barnard` state in the app's SwiftPM `Package.resolved`. All three
version/commit values must agree.

The Android JSON format name is `beid-android-package-inspection-v1`. It
contains:

* packaged `build.versionName` and positive integer `build.versionCode`;
* packaged `barnard.tag` and 40-hex `barnard.commit`;
* `dependencyProof.kind`, exactly `gradle-lock` or `dependency-insight`, and
  its fully qualified `dependencyProof.coordinate`;
* the same provenance and receipt fields as iOS.

The Android check reuses the existing Gradle declaration reader. A coordinate
match is accepted only inside the build-time proof; a Maven version by itself
is never treated as Beid source provenance. There is no checked-in Gradle lock
at the target ref, so an authenticated dependency-insight export from the
actual packaged build is the expected equivalent unless a lock is supplied.

Receipt SHA-256 values are identifiers copied from the approved immutable
export. Whoever supplies evidence must authenticate that export or package
before running this offline reader; this tool deliberately performs no network
login and does not pretend that a self-authored JSON file authenticates itself.

## Fail-closed generation

Run from a Beid checkout containing candidate `7f4e34262a0877cc4812d4f7d095d6ef71d09410`:

```sh
python3 scripts/generate_release_supplier_manifest.py \
  --ios-evidence /immutable/ios-approved-metadata.json \
  --android-evidence /immutable/android-package-inspection.json \
  --candidate-sha 7f4e34262a0877cc4812d4f7d095d6ef71d09410 \
  --output /tmp/parallax-beid-supplier.json
```

Success prints the candidate SHA, count `2 builds`, count `2 agreeing Barnard
identities`, and exits 0. Missing/stale provenance, an absent packaged
identity, source/package pin drift, dependency-proof drift, or different iOS
and Android identities exits 1 and creates no output. The common `barnard`
object is constructed only after both concrete identities agree.

The production export is pending. It needs approved packaged identities and
provenance for both platforms. Android's packaged version name and code supply
`builds.android`. Its concrete Barnard tag and commit must agree with iOS
before emitting `barnard.tag` and `barnard.commit`. The Android dependency
declaration alone cannot establish that evidence.

## Explicitly synthetic exercise

The checked-in fixtures are visibly marked `"synthetic": true`; production
invocation rejects them. Exercise the match case only with the explicit test
switch:

```sh
python3 scripts/generate_release_supplier_manifest.py \
  --ios-evidence scripts/tests/fixtures/release_supplier/ios-match.json \
  --android-evidence scripts/tests/fixtures/release_supplier/android-match.json \
  --candidate-sha 7f4e34262a0877cc4812d4f7d095d6ef71d09410 \
  --allow-synthetic --output /tmp/synthetic-parallax-beid-supplier.json
```

That command exits 0 with the two counts above. Replacing the Android path with
`android-missing-identity.json` or `android-mismatched-proof.json` exits 1,
reports the exact missing/inconsistent field, and emits no candidate manifest.
Omitting `--allow-synthetic` also exits 1.
