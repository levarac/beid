# beid-lab-cli

A headless macOS command-line tool that puts a Mac on the beid radio as an
observer, a venue device, or an additional participant, and reports what
happens as JSON lines.

It exists so a measurement in a room can use Macs alongside the phones. A Mac
running `participate` is an **additional participant, not a substitute for a
phone** — beid's confirmation threshold counts distinct devices, so extra
Macs reduce how many phones each phone needs to see, and the four-device gate
in beid#218 is unaffected.

Built with SwiftPM only: no Xcode project, no XcodeGen, no DerivedData at
build or run time. It depends on the Barnard Swift package at the same exact
version `ios/project.yml` pins, and
`scripts/check_lab_cli_barnard_pin.py` fails the two apart — a lab tool that
measured a different SDK than the app ships would produce numbers nobody can
use, and would produce them silently.

---

## The trap: the event code is not the join string

**Read this before running `participate`.** It has already cost one
measurement window.

beid does not join an event with the code a human was told. Two different
strings are both called "the event code" by different audiences:

| | Example | What it is for |
| --- | --- | --- |
| **Operator lookup code** | `parallax-sepolia-20260917-05` | Typing into a UI, looking up a registration. Never goes on the wire. |
| **Join string** | `9f3c…0718` (64 lowercase hex) | The canonical Event ID. **This is what `BarnardEngine.joinEvent` receives.** |

`shared/`'s `RegistryVerifiedJoinContext` carries a `joinCode` field whose doc
calls it "the exact string the native adapter hands
`BarnardEngine.joinEvent`", and both of its construction paths set it to
`canonicalEventIdHex`. The same doc says the rest outright: *the operator's
human code remains a lookup/UI input only.*

From there the chain is arithmetic. Barnard derives B004 as the first eight
bytes of SHA-256 over the join string's UTF-8 bytes
(`BarnardCoreCrypto.computeEventCodeHash`). The signed definition carries the
same value computed from the raw Event ID
(`BarnardB005EnvelopeV2.openEventCodeHash`, which hex-renders it and hashes
that). The two agree **by construction** — as long as the join string really
was the Event ID hex.

### Why the wrong string is worse than an error

On 2026-09-17 a run joined with the operator lookup code. Every layer behaved
correctly: the Mac derived B004 from what it was handed, the phones derived
theirs from the Event ID, the values differed, and `BarnardEngine` discarded
every peer at its gate *before reading B002*
(`BarnardEngine.swift:2088-2113`). A detection needs B002, so none was
emitted, and no phone's count moved.

Nothing failed. The run exited 0 and reported a clean hold. **It looked
exactly like a run where nobody was in the room.**

That is why this tool **refuses** a non-canonical `--event-code` instead of
warning about it, and why `--event-id` is the documented way in.

### Case matters

What gets hashed is the *characters*. `9F` and `9f` are different join
strings with different B004 values, so an uppercase Event ID of the right
length is still wrong. `--event-id` normalises for you (strips `0x`,
lowercases); `--event-code` does not, because its whole purpose is to pass a
string through verbatim.

---

## Subcommands

```sh
beid-lab-cli <observe|venue|participate> [options]
```

### `observe`

Records advertisements on the air and **never connects to anything**.

This is the instrument for "did the venue really stop emitting"
(dispatch#66). `BarnardEngine`'s own scan is not passive — every discovery
that clears its RSSI guard is enqueued for a connect, and a connect leads to
GATT reads — so an engine-based observer would perturb what it measures.
`ObserveRunner` is therefore a bare `CBCentralManager` with one delegate
callback and no connection path at all.
`scripts/check_observe_never_connects.py` fails CI if one is ever added,
because that change would look like an ordinary feature in review and would
silently invalidate every measurement taken afterwards.

A stop is an **absence**: nothing arrives to log. So the measurement is the
`peer_lost` line, whose `lastSeen` is the answer and whose `elapsed` is
merely when the deadline fell due. Every open interval is closed at the end
of the run, so a device still advertising when the window ends still gets an
end line and the log can be read as intervals.

```sh
beid-lab-cli observe --timeout 600 --lost-after 10 --log ~/observe.jsonl
```

| Option | Default | Meaning |
| --- | --- | --- |
| `--lost-after <seconds>` | 10 | Quiet time before `peer_lost`. |
| `--repeat-every <seconds>` | 5 | Gap between repeat sighting lines. `0` prints every advertisement. |

The scan names Barnard's discovery service rather than passing `nil`: an iOS
app advertising in the background moves its service UUID into the
advertisement's overflow area, which CoreBluetooth surfaces **only** to a
scan that names that UUID. A `nil` filter would miss exactly the backgrounded
phones this is pointed at.

A local 20-second run on 2026-09-17 saw the shape this predicts: a peripheral
matched the B001 filter while its `CBAdvertisementDataServiceUUIDsKey` came
through empty, so whatever matched was not in the visible advertisement.
That is consistent with the overflow area and is the reason to keep the named
filter — but the run observed the symptom, not the mechanism, and no phone
was instrumented to confirm what it actually broadcast.

### `venue`

Serves a signed event-info container and advertises.

```sh
beid-lab-cli venue --container ~/event-05.container --timeout 900
```

The container arrives already signed. `configureOwnEventInfoEnvelopeV2`
serves those bytes verbatim — the SDK does not sign, re-encode or re-verify
them — so this subcommand supplies bytes and performs **no venue policy**: it
does not choose a slice from a schedule, extend a deadline, or treat reading
a file as permission to serve.

`configure(eventCode:)` is never called and `--event-code` is refused here. A
signed container is served without the engine knowing any code, exactly as
`BarnardVenueSignedContainerBroadcasting` does on iOS; joining one would put
a participant B004 on the air beside real participants.

The `venue_ready` line reports what the container claims about itself —
event id, display name, ENIN window, and the same window in Unix seconds
next to the host's clock — so an operator who copied the wrong file finds out
before the phones do. Whether the window is open *now* is deliberately not
this tool's call.

| Option | Meaning |
| --- | --- |
| `--container <path>` | File holding the signed hop-zero B005 v2 container. |
| `--container-hex <hex>` | The same bytes, pasted. |

**Bundles are not supported, on purpose.** A venue *bundle* is CBOR and
selecting its current slice is lease logic; both live in
`shared/.../parallax/venue` and belong to both apps. Writing a Swift decoder
here would be a second implementation of a shared decision, which
`AGENTS.md`'s ownership boundary forbids, and issue #588's own scope says
this CLI is Barnard-only with no shared macOS build. Extract the envelope
with the tooling that owns bundle decoding and pass the container.

### `participate`

Joins an event, scans and advertises at once, and reports what resolved.

```sh
# The way that matches the phones.
beid-lab-cli participate --event-id 9f3c…0718 --timeout 600

# Take the Event ID out of the same signed bytes the venue serves.
beid-lab-cli participate --container ~/event-05.container --timeout 600

# A deliberately synthetic rehearsal. Cannot move any phone's count, which is
# what makes it safe to run beside a live measurement.
beid-lab-cli participate --event-code LABPROBE1 --allow-noncanonical-code
```

Pass exactly one join source.

| Option | Default | Meaning |
| --- | --- | --- |
| `--event-id <64 hex>` | — | The canonical Event ID. Normalised (`0x` stripped, lowercased). |
| `--container <path>` | — | Take the Event ID from a signed container. |
| `--event-code <string>` | — | A raw join string, passed verbatim. Refused unless canonical or acknowledged. |
| `--allow-noncanonical-code` | off | Go ahead with a non-canonical `--event-code`. |
| `--role advertise\|scan\|auto` | `auto` | Which half of the radio to use. |
| `--expect-peers <n>` | 0 | Peers required to pass. **0 is a hold**: stay on the radio for the whole timeout, which is the usual reason to run this. |
| `--relay on\|off` | off | Spec 134 participant relay. See the warning below. |
| `--enin-seconds <n>` | engine's | ENIN length, 12–3600. |
| `--enin-mode fixedLength\|beaconSlot` | engine's | ENIN mode. |

ENIN parameters are passed to the engine **only** when you ask for them.
Neither beid app calls `configure` with ENIN arguments, so leaving them alone
is what keeps a run comparable with the phones. Values outside 12–3600 are
refused rather than clamped: the engine clamps silently, and an operator who
asked for 5 should learn they would have got 12 instead of reading a
comparable-looking log derived from a different window.

#### `--relay on` installs a verifier that lies

`LabPermissiveRelayVerifier` reports `REGISTRY_VERIFIED` for any
signature-valid envelope with **no registry read at all**. Spec 134 says that
answer may only come from an authenticated registry read. It exists so the
lab can make the relay path fire between machines it owns, on an event it
created. Do not copy it into a product. The CLI prints a warning line at
`error` level whenever it is installed, so no log can show a relay decision
without also showing what produced it.

---

## Log levels

Every line carries its own `level`, so one saved capture can be filtered
afterwards rather than re-run at a different setting.

| Level | What it adds |
| --- | --- |
| `error` | The run's verdict and why it could not proceed. |
| `info` *(default)* | The milestone stages, plus GATT failures. |
| `debug` (`-v`) | Every engine event and debug callback: discoveries with RSSI, GATT reads and writes with sizes and status, state changes, timers. |
| `trace` (`-vv`) | Raw bytes as hex for non-secret fields, and the engine's own reason codes. |

A level **admits itself and everything above it in severity**, so raising the
level keeps the milestone lines rather than replacing them. The `result` line
is written at `error`, so no setting can produce a log with no verdict in it.

### What never reaches the log

Key material, at any level. Ever.

RPIDs are full hex **only at `trace`** and a four-character prefix
everywhere else. Note that this relaxes issue #588's text, which said no raw
RPID at any level; the relaxation is Ken's instruction of 2026-09-17, and it
is written down here rather than left for a reader to discover.

### What is logged in full, and why that is not a leak

Some values are printed whole at `info`. The rule is not "short things are
safe" — it is **whether the value is already public by construction**, which
for this tool means: is it on the wire, or derivable by anyone who was in the
room.

| Value | Level | Why |
| --- | --- | --- |
| `b004` (event-code hash) | full, `info` | Served over GATT to anything that connects, and carried in the signed definition. A run's own B004 is the single most useful line for diagnosing a gate mismatch, and withholding it would hide the thing the log exists to show. |
| `payloadDigest` (relay) | full, `info` | A local dedup key over an envelope that is itself broadcast. It identifies a *message*, not a person or a device. |
| `eventDisplayName` | full, `info` | On the wire by design — it is what a participant is shown. |
| `peer` in **`observe`** — a `CBPeripheral.identifier` | full | A CoreBluetooth per-host UUID. It is not a hardware address and **not stable across machines**, so it identifies nothing outside this one run. Truncating it would create collisions and destroy the only way to correlate two lines about one device. |
| `peer` in **`participate`** — a `displayId` | prefix below `trace` | A different value under the same key, with the opposite property. `displayId` is `SHA256(TEK)[0:4]`, served over B003 and rotating with the TEK, so it **is** on the wire and therefore identical on every machine that sees it — that is the whole reason two devices can recognise each other by it. Same rotating-pseudonym class as an RPID, so it is redacted on the same terms. |
| `myDisplayId` (this host's own) | prefix below `trace` | Same value class, same treatment. Correlating two hosts' logs by it needs `-vv`. |
| RPID | prefix below `trace` | On the wire, but rotating and person-linked. |
| Join string | prefix below `trace` | **Not** on the wire. Only its hash is. |
| Key material | never, any level | — |

The two `peer` rows are the pair most likely to be misread, because one key
carries two values with opposite properties. An earlier version of this table
had a single row justified by "a CoreBluetooth per-host value" — true of the
`observe` value and false of the other, which is on the wire by design. The
`participate` value is a pseudonym and is treated as one.

Counting is unaffected by any of this: the peer set uses whole values, so
`peers` in the closing `result` line is exact whatever the log shows.

The last two rows are the pair worth reading together, because printing a
hash while redacting its input looks inconsistent until you ask what an
attacker gains. For a canonical Event ID the preimage is 32 random bytes, so
publishing `b004` reveals nothing that reading the air would not. For a
low-entropy synthetic code — `LABPROBE1` — the hash **is** reversible by
dictionary attack, and the four-character prefix leaks besides. That is
accepted rather than overlooked: a synthetic code is not a secret, it exists
so a rehearsal cannot touch a real event. Do not read the join string's
redaction as protection for a code you actually needed to keep.

Redaction is a **mapping, not a passthrough**. The Barnard lab runner
forwards every JSON-valid field a debug callback carries, which is why its
logs contain raw RPIDs and why a field the SDK adds tomorrow would be logged
in full the day it appears. Here the rule is stated over *shapes*:

- numbers and booleans pass through — an identifier is not an `Int`;
- a string under a known-neutral key (`reason`, `state`, `receiverState`, …)
  passes through;
- **any other string is treated as potentially identifying** and is cut to a
  prefix below `trace`, whether or not this tool has heard of the key.

The last rule is the load-bearing one: an unrecognised field degrades to
redacted rather than to logged.

---

## JSON lines schema

One JSON object per line on stdout, and to `--log <path>` if given. Every
line carries the same seven keys, present even when empty, so a mixed log is
filterable with one `jq` expression.

```json
{"data":{},"event":null,"level":"info","mode":"observe","result":"ok","stage":"scan_start","ts":"2026-09-17T03:08:31.623Z"}
```

| Key | Meaning |
| --- | --- |
| `ts` | UTC, milliseconds, `Z` suffix. |
| `level` | The line's own level (see above). |
| `mode` | `observe`, `venue` or `participate`. |
| `stage` | What happened. Table below. |
| `event` | First 8 hex of the run's Event ID, or `null`. |
| `result` | `ok`, `match`, `mismatch`, `timeout`, `rejected`, `unavailable`, `interrupted`. |
| `data` | Stage-specific fields. Nested rather than flattened, so a payload key can never collide with one of the six above. |

### Stages

| Stage | When |
| --- | --- |
| `run_start` | Once per run, plus the join string and its derived B004 for `participate`. |
| `permissions` | The engine's permission answer. |
| `scan_start` | Scanning began. |
| `advertise_requested` | Advertising was **requested** — see the note below. |
| `advertise_stop` | Advertising stopped and any container was cleared. |
| `venue_ready` | The container was accepted; what it says about itself. |
| `discovery` | One advertisement (`observe`), or a repeat sighting. |
| `peer_first_seen` / `peer_lost` | Interval boundaries. |
| `gatt_connect` | Connect attempts and completions. |
| `gatt_resolution` | A GATT exchange that did not finish: timeout, missing service, failed read, backoff. |
| `gatt_b004` | The event-code-hash read and its verdict. |
| `detection` | A resolved peer. |
| `envelope_v2` | A B005 v2 envelope was received or hinted. |
| `state` / `constraint` / `relay` | Engine state, constraints, relay decisions. |
| `engine_debug` | Any other engine callback, at `debug`. |
| `failure` | An engine error, a rejected container, a denied radio. |
| `result` | The last line of every run, always. |

### `advertise_requested`, not `advertise_start`

`BarnardEngine` sets `isAdvertising = true` the moment advertising is
requested and has **no OS-confirmed success event**
(`docs/venue-serving-contract.md`). So this tool records a request. **Only a
receiver proves the air** — if you need to know that something was actually
broadcast, read it off a phone, not off this log.

### Reading a run

```sh
# Did the venue stop, and when?
jq -c 'select(.stage=="peer_lost") | {peer:.data.peer, lastSeen:.data.lastSeen}' run.jsonl

# Did the B004 gate pass?
jq -c 'select(.stage=="gatt_b004") | .result' run.jsonl | sort | uniq -c

# The verdict, on its own.
jq -c 'select(.stage=="result")' run.jsonl
```

A `participate` run that resolved nothing is a **different finding** from an
empty room, so the closing line carries `gattConnectAttempts`,
`gattConnectsCompleted`, `gattResolutionFailures` and `gattFailureReasons`
alongside the peer count. Run 2 on 2026-09-17 was 18 failures, 0 matches and
0 mismatches, and only the first of those numbers says why.

---

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | The run did what it was asked for the whole window. |
| 1 | Arguments, a missing file, or an interrupt. The radio produced no verdict. |
| 2 | The radio worked and the expectation was not met. Only `participate --expect-peers` can produce this. |
| 3 | Bluetooth denied, restricted, powered off, unsupported, or the one-time grant has not been made. **A host that needs a person, not a result about the radio.** |

Keeping 2 and 3 apart is the point: a run that could not use the radio has
produced no measurement, and reporting it as a failed one would put a
meaningless number in a report.

---

## Building and running

```sh
./scripts/run.sh --codesign-identity "Apple Development: ..." \
    observe --timeout 60 --log ~/observe.jsonl
```

`run.sh` calls `scripts/bundle.sh`, which runs `swift build -c release`,
assembles `build/BeidLabCli.app` around the binary, writes its `Info.plist`,
and codesigns it — then `exec`s the binary so a backgrounded PID is the CLI
itself and a `SIGTERM` reaches its own handler, which is what stops the radio
and writes the closing line. Build output goes to stderr; stdout is JSON
lines only.

`--build-only` bundles and stops. `--skip-build` (or `SKIP_BUILD=1`) launches
an already-bundled app. `CODESIGN_IDENTITY` is honoured as a fallback for
`--codesign-identity`, so an existing device-lab orchestrator keeps working.

### The `.app` wrapper is not cosmetic

macOS keys the Bluetooth grant to a **bundle identity plus a code
signature**. A bare executable is a different, unnamed thing on every run.
`bundle.sh` signs ad-hoc by default so this builds on any Mac and in CI with
no keychain — but an ad-hoc signature changes on every rebuild, which drops
the grant and re-prompts. Set a stable `CODESIGN_IDENTITY` and the grant
survives rebuilds. A paid developer account is not required: a self-signed
code-signing certificate made in Keychain Access, trusted on that machine
only, is enough.

Nothing here can answer the Bluetooth prompt, and nothing tries. Somebody has
to approve it once, at that machine's desktop session, over screen sharing if
it is headless. Afterwards it appears under System Settings → Privacy &
Security → Bluetooth as `BeidLabCli`.

---

## Running on a second Mac over ssh

The tool is one self-contained executable inside a `.app`. Nothing about
running it needs a repository checkout, an Xcode project, or DerivedData.

```sh
# On the build Mac
cd tools/beid-lab-cli
./scripts/run.sh --build-only
tar -C build -czf /tmp/beid-lab-cli.tgz BeidLabCli.app
scp /tmp/beid-lab-cli.tgz altair:~/

# On the remote Mac
tar -xzf ~/beid-lab-cli.tgz
codesign --force --sign "$CODESIGN_IDENTITY" \
    --identifier org.levarac.beid.lab-cli ~/BeidLabCli.app

# Approve the one-time Bluetooth prompt once, at that machine's desktop
# session. Then:
~/BeidLabCli.app/Contents/MacOS/beid-lab-cli observe \
    --timeout 600 --log ~/observe.jsonl
echo "exit=$?"

# Back on the build Mac
scp altair:~/observe.jsonl ./
```

Two things to know before the room is live rather than after:

- **The copied binary runs on the remote Mac only if it is also Apple Silicon
  and at or above macOS 12.** Otherwise build from a checkout there instead;
  the toolchain needed is `swift build` and `codesign`, nothing more.
- **Re-signing creates a new signature, so that Mac asks for its own one-time
  Bluetooth grant.** It is per machine and per signature, it needs a person
  at a desktop session, and no amount of ssh will answer it.

The CLI performs **no network access of any kind** (Ken, 2026-09-17). This
supersedes issue #588's "bundle / handoff URL or file": a URL passed to
`--container` is refused with the rule rather than left to fail later as a
missing file. Copy the file to the host.

---

## Tests

```sh
swift test                                             # 86 tests
python3 -m unittest discover -s ../../scripts/tests -t ../..   # includes both checkers
```

`BeidLabCliCore` imports Foundation and nothing else, so its 82 tests run on
a host with no Bluetooth — which is every CI runner GitHub offers, and the
reason the Barnard lab runner's own CI job is build-only.

`BeidLabCliBarnardTests` links the SDK but still needs no radio: it asserts
that Barnard's two independent paths to B004 agree through
`LabEventCode.joinString`, over five Event IDs spread across the byte range.
That is an **agreement test rather than a fixture** on purpose. A fixture is
a value somebody copied out of a log, produced by the same reasoning as the
code, and it cannot notice that the definition side moved. This one fails if
either side of the SDK drifts, if the normalisation changes, or if this tool
stops producing what the app produces.

Both Python checkers run in PR CI through the existing
`unittest discover -s scripts/tests` step; no workflow change was needed.
They also test their own silent-pass failure mode — a guard that quietly
checks nothing looks exactly like a guard that passes — so a missing source
file fails rather than reporting success.

---

## What this tool does not do

- **No network.** No registry resolution, no bundle fetching, no submission.
- **No records of its own.** A Mac here is one participant's radio; the
  phones produce the record. Aggregation, the ledger and submission are the
  `SensingCoordinator` layer and stay in the app.
- **No `shared/` module.** The CLI is Barnard-only, so nothing here decides
  anything both apps must agree on. Where a shared decision was needed —
  bundle decode, lease selection — this tool takes the already-decided
  artifact instead of re-deciding it.
- **No proof of transmission.** `advertise_requested` means requested. Only a
  receiver proves the air.
