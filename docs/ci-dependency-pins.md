# CI dependency pins

Verified 2026-09-26. Each SHA was resolved through the upstream GitHub commit
API, and its action manifest was inspected at that SHA for runtime and entry
points. These are JavaScript actions (Node 20 or 24), with no nested composite
`uses:` dependencies. This provenance check is not a full audit of bundled
JavaScript or its transitive dependencies. Review upstream source changes before
updating a pin; never copy a SHA from an unrelated repository.

| Action | Tag | Commit / source |
| --- | --- | --- |
| `actions/upload-artifact` | `v7.0.1` | [`043fb46d1a93c77aae656e7c1c64a875d1fc6a0a`](https://github.com/actions/upload-artifact/blob/043fb46d1a93c77aae656e7c1c64a875d1fc6a0a/action.yml) |
| `actions/download-artifact` | `v8.0.1` | [`3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c`](https://github.com/actions/download-artifact/blob/3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c/action.yml) |
| `actions/cache` | `v4` | [`0057852bfaa89a56745cba8c7296529d2fc39830`](https://github.com/actions/cache/blob/0057852bfaa89a56745cba8c7296529d2fc39830/action.yml) |
| `actions/checkout` | `v4` | [`11d5960a326750d5838078e36cf38b85af677262`](https://github.com/actions/checkout/blob/11d5960a326750d5838078e36cf38b85af677262/action.yml) |
| `actions/github-script` | `v7` | [`f28e40c7f34bde8b3046d885e986cb6290c5673b`](https://github.com/actions/github-script/blob/f28e40c7f34bde8b3046d885e986cb6290c5673b/action.yml) |
| `actions/setup-java` | `v5` | [`b6effb05e454b25005698d916606bdc6ffcbf961`](https://github.com/actions/setup-java/blob/b6effb05e454b25005698d916606bdc6ffcbf961/action.yml) |
| `actions/setup-java` | `v4` | [`cf277c60eb25467037889841efdb72551f06f6c3`](https://github.com/actions/setup-java/blob/cf277c60eb25467037889841efdb72551f06f6c3/action.yml) |
| `android-actions/setup-android` | `v4` | [`be39fa834029ff78f1a44aa3bb0819b8fc2bd8fd`](https://github.com/android-actions/setup-android/blob/be39fa834029ff78f1a44aa3bb0819b8fc2bd8fd/action.yml) |
| `gradle/actions/setup-gradle` | `v4` | [`ed408507eac070d1f99cc633dbcf757c94c7933a`](https://github.com/gradle/actions/blob/ed408507eac070d1f99cc633dbcf757c94c7933a/setup-gradle/action.yml) |
| `r0adkll/upload-google-play` | `v1.1.5` | [`e738b9dd8f2476ea806d921b64aacd24f34515a5`](https://github.com/r0adkll/upload-google-play/blob/e738b9dd8f2476ea806d921b64aacd24f34515a5/action.yml) |

XcodeGen 2.45.3 uses the official `xcodegen.zip` release asset. The release API
reported SHA256 `0c90f4d28ca57335f9fa78cf5bf6dabfe20a232036dabe36de2eef79cb7c0878`,
which matched the downloaded archive locally. The version and digest are committed
beside the Xcode Cloud scripts. `scripts/download_xcodegen.sh` checks the digest
before extraction and requires both the executable and SettingPresets.

Source: [XcodeGen 2.45.3 release](https://github.com/yonaskolb/XcodeGen/releases/tag/2.45.3).
Both the version and hash must be reviewed together when upgrading. Never derive
the expected digest from the archive being verified at runtime.

Artifact actions were verified on 2026-09-27 from the upstream release tags and manifests. Both run Node 24; upload enters `dist/upload/index.js`, download enters `dist/index.js`, with no nested composite actions. Download uses the default digest-mismatch error policy.
