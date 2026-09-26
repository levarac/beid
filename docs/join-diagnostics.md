# Debug join diagnostics

Debug builds emit one `join_stage` line for each observed join stage through
an injectable native sink. Android uses the `BeidRuntimeDiagnostics` logcat
tag; iOS uses the `BeidRuntimeDiagnostics` subsystem and `sensing` category,
with public interpolation. Release builds do not emit these lines.

```text
join_stage event_id=01234567 stage=registry_resolution outcome=rejected_verification_unavailable attempt=2 retry_at_epoch_ms=1800000035000
```

- `event_id`: the first eight hex characters of a canonical Event ID, or
  `unknown` before a verified envelope or registry answer supplies one.
  Event codes, event-code hashes, peripheral identifiers, raw RPID values,
  envelopes, names, keys, and raw error messages are excluded.
- `stage`: `detection`, `envelope_verification`, `registry_lookup` (manual
  code-to-ID lookup), `registry_resolution`, or `admission`.
- `outcome`: `detected`, `started`, `success`, `admitted`, or a fixed
  `rejected_*` category. A successful registry read is distinct from
  admission: the event can still be ineligible to join.
- `attempt`: one-based lookup or resolution attempt number, or `none` for
  stages outside an attempt. An attempt can end before network I/O, for
  example when no registry is configured. Nearby retries use the shared
  candidate's failure count.
- `retry_at_epoch_ms`: the shared candidate's next retry deadline in Unix
  milliseconds, or `none`. A failed nearby resolution logs the deadline,
  and each subsequent attempt logs its start, even without another beacon.

V1 hints do not carry a canonical Event ID. An unverified v2 receipt has no
trusted identity either; neither substitutes another identifier for it.
A v2 receipt logs detection even when no v1 hint preceded it.

For a physical Android device, substitute the current app PID:

```sh
adb logcat --pid <beid-pid> -s BeidRuntimeDiagnostics:D
```

For the iOS unified log, enable Debug-level messages and filter by subsystem:

```sh
log stream --level debug --predicate 'subsystem == "BeidRuntimeDiagnostics"'
```

Run that command in the environment whose unified log contains the app, or
select the connected iOS device in Console.app. A Mac's own log stream does
not establish what a connected iPhone emitted. Simulator/unit-test evidence
does not prove physical BLE reception or device-console delivery; both
physical-device excerpts remain part of issue #583's acceptance.
