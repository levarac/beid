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
entries. Native adapters observe only existing UI state. iOS records scan phases and
join-refusal categories; Android records join-session states (including scan
phases, permission and owner-key failures). This is not a general logging tap. Times are device-clock hour buckets (not trusted server time), coarser than
the supported window durations. Exact sighting times are not emitted. History is memory-only and
resets when the process ends. This is not a crash log or a submission audit.

The output includes schema version, platform, app version, build, and recent
state/failure entries. No free-form error descriptions, event names/codes,
identifiers, wallet details, HTTP bodies, or stored artifacts are accepted.
Unknown reason strings become an enum sentinel. Invalid version/build strings
become `unknown`. Failure categories describe the UI's existing decision.

Tests inspect the actual exported UTF-8 JSON and native share payloads with
synthetic sensitive markers, 17-byte RPID hex/base64 values, prefixes, suffixes
and an unsalted SHA-256 in rejected metadata, reason strings, and UI event
payloads. They do not seed or read real observation/key/ledger stores.
