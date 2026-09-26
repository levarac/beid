# Device support bundle

The privacy predicate is owned by [Parallax issue 74](https://github.com/levarac/parallax/issues/74),
under [dispatch issue 44](https://github.com/levarac/dispatch/issues/44).
Its [privacy predicate proposal](https://github.com/levarac/parallax/issues/74#issuecomment-5846858083)
is pending a maintainer decision. This implementation follows that proposal
with a closed set of diagnostic fields and does not redefine it or claim the
upstream acceptance dependency is complete.

| family | class | current_ios | current_android | ruling_or_invariant | owner | shared_symbol | licensing_test | platform_callers | status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| support bundle | C / INVENT | absent | absent | bounded process-local state history; only enum states/reasons and build metadata; no observation, ledger or key store access | beid #466; privacy: Parallax #74 | SupportBundleRecorder | SupportBundleRecorderTest | SupportDiagnostics / SupportDiagnostics | implementation |

Both Account surfaces offer **Share support information**. Tapping it creates
a JSON text snapshot and opens the system share sheet. The user chooses the
destination or cancels; the app has no automatic upload or diagnostic file.
The screen explains the contents and that history covers this app session.

The shared implementation owns the JSON schema, metadata validation, fixed
reason vocabulary, duplicate suppression, and retention of the latest 100
entries. Native adapters observe only existing UI state. iOS records scan phases,
join-refusal categories and published owner-key failures (including an already
latched failure at subscription). Android records join-session states (including
scan phases, permission and owner-key failures).

The remaining platform difference is intentional: Android's `EventJoinUiState`
has `REQUESTING_PERMISSION`, `VERIFYING_REGISTRY` and `PERMISSION_DENIED`
counterparts. iOS's observed `ScanPhase` and join-refusal publishers do not
represent those intermediate permission/verification states. iOS permission
screens belong to the separate `AppCoordinator`/`BluetoothMonitor` onboarding
flow, and registry work happens inside `SensingCoordinator` without a matching
published scan phase. This slice does not add lifecycle instrumentation or infer
those states from screen appearance; their absence in an iOS bundle does not
prove permission or registry success. Both platforms do record the existing
published owner-key failure as `OWNER_KEY_UNAVAILABLE` without its storage detail.

This is not a general logging tap. Times are device-clock hour buckets (not trusted server time), coarser than
the supported window durations. Exact sighting times are not emitted. History is memory-only and
resets when the process ends. This is not a crash log or a submission audit.

The top-level keys are exactly `schemaVersion`, `platform`, `appVersion`, `build`,
`gitHeight`, `historyScope`, and `entries`. Each entry has exactly
`hourStartEpochMs`, `state`, and `failure`; the last two contain only shared enum
values. `gitHeight` reads the existing public build identifier from Android's
`BuildConfig.GIT_HEIGHT` and iOS's `BeidGitHeight` bundle key. One to ten ASCII
decimal digits become a JSON number (leading zeroes are normalized); missing,
local or invalid metadata becomes JSON `null`. This distinguishes delivered
Android builds whose version name/code are fixed without accepting arbitrary text.

No free-form error descriptions, event names/codes,
identifiers, wallet details, HTTP bodies, or stored artifacts are accepted.
Unknown reason strings become an enum sentinel. Invalid version/build strings
become `unknown`. Failure categories describe the UI's existing decision.

Tests inspect the actual exported UTF-8 JSON and native share payloads with
synthetic sensitive markers, 17-byte RPID hex/base64 values, prefixes, suffixes
and unsalted SHA-256 of both the raw bytes and their hex text in rejected metadata,
reason strings, and UI event payloads. Seeds include iOS venue and canonical Event
ID fields and Android signal-lost/owner-key-failure payloads. Exact schema key
sets and every emitted enum value are asserted on parsed JSON. A per-entry
`detail` string mutation makes that test fail. Tests do not seed or read real
observation/key/ledger stores.
