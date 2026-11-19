# Testing venue broadcast and mutual sensing with a test event

How to check, on your own devices, that Beid can import an event, broadcast it as a venue, and that participants sense each other. It covers iPhones and Macs. For the measurement procedures behind specific issues, see [field-test-procedure.md](field-test-procedure.md); for the headless Mac tool, see [tools/beid-lab-cli/README.md](../tools/beid-lab-cli/README.md).

## What you need before you start

**A registered, currently open event.** Since #410, Beid starts no radio for an event that does not pass registry verification, so a made-up event code senses nothing on any number of devices. Ask the maintainer who registers events for these three values:

| Value | Example shape | Used for |
| --- | --- | --- |
| `<EVENT_CODE>` | `parallax-sepolia-YYYYMMDD-name` | Typing into the app. A lookup string; it never goes on the air. |
| `<EVENT_ID>` | 64 lowercase hex characters | The canonical Event ID. Passed to `beid-lab-cli`. |
| Venue link or QR | an `https://…r2.dev/#…` link, shown as a QR code | Importing the event on the device that broadcasts as the venue. |

Also check the event's validity window (its start and end time). Outside it, joining is refused.

**The event code and the Event ID are different strings.** The app takes the event code. `beid-lab-cli --event-id` takes the Event ID. Mixing them up does not produce an error; it produces a run in which nobody is detected (see the lab CLI README).

**At least four participating devices.** A device records only after it has verified three others ([`defaultEventConfirmThreshold = 3`](../shared/src/commonMain/kotlin/org/levarac/beid/shared/sensing/EventConfirmThreshold.kt)), so three phones sense each other but never reach recording. Venue devices do not count; a Mac running `beid-lab-cli participate` does.

**The same build on every device.** A mixed set of builds can fail silently. Read out the build number on each device before starting.

## 1. Join on iPhone

1. Install Beid (the current TestFlight build, or your own development build).
2. Open Collection → Sense Event → Enter event code, type `<EVENT_CODE>`, and tap Join event.
3. If the device is already in another event, leave it first, then join.

## 2. Broadcast as the venue (one iPhone)

1. On the iPhone that will act as the venue, open Account → Venue broadcast → Scan QR code and scan the venue QR.
2. Check that the Event ID it shows equals `<EVENT_ID>`.
3. While it broadcasts, other devices show a nearby-event card in Sense Event and can join from there instead of typing the code.

Showing the QR on a computer screen is not a broadcast. The broadcast comes from the iPhone that imported the QR.

A venue bundle holds one signed envelope per hour of the event, up to 512. Long events therefore produce large bundles; if an import fails, record the exact error text.

## 3. Run on a Mac

### A. Beid on a Mac (Apple Silicon, Designed for iPad)

In Xcode, pick the Beid scheme, choose "My Mac (Designed for iPad)" as the destination, and Run. Launch and screen display have been confirmed on a Mac; joining, the Bluetooth grant and sensing over the air have not yet been confirmed there.

### B. `beid-lab-cli` as an additional participant

The headless tool puts a Mac on the radio as an extra participant. It adds to the device count; it does not stand in for a phone.

```sh
cd tools/beid-lab-cli
./scripts/run.sh --build-only
./scripts/run.sh --skip-build participate --event-id <EVENT_ID> --timeout 600 -v > ~/participate.jsonl
```

- On first run, macOS asks for Bluetooth permission. Approve it at that Mac's desktop. It then appears under System Settings → Privacy & Security → Bluetooth as `BeidLabCli`.
- The default ad-hoc signature changes on every rebuild, which drops the grant. To keep it, sign with a stable identity (`--codesign-identity` or `CODESIGN_IDENTITY`); a self-signed code-signing certificate made in Keychain Access is enough.
- Output is one JSON object per line; `-v` adds discoveries with RSSI.
- Exit codes: 0 ran the whole window as asked; 1 arguments or a missing file; 2 the expected peer count was not reached (only with `--expect-peers`); 3 Bluetooth unavailable (not yet granted, off, or restricted).

### C. A Mac as the venue

`beid-lab-cli venue` can broadcast the event from a Mac instead of an iPhone. What it broadcasts is a hop-zero delivery container: one signed envelope behind a 4-byte header (format, relay hop count, length). The time window belongs to the envelope inside, and phones accept it for about one hour, so the Mac needs the next delivery container every hour. Cut the current delivery container from the event's venue bundle with `tools/event-occurrence/delivery-container.mjs` in levarac/parallax (a private repository; project members have read access). The bundle is public and holds no keys: it is on the venue link's host at `/artifacts/venue-bundles/<EVENT_ID>`.

```sh
curl -fsS -o venue-bundle.cbor "https://<venue link host>/artifacts/venue-bundles/<EVENT_ID>"
node <parallax checkout>/tools/event-occurrence/delivery-container.mjs --bundle venue-bundle.cbor --out delivery-container.bin
cd tools/beid-lab-cli
./scripts/run.sh --skip-build venue --container ../../delivery-container.bin --timeout <secondsLeft>
```

- `delivery-container.mjs` prints `secondsLeft`, the time until phones stop accepting this delivery container. Pass it as `--timeout`, then cut the next delivery container and start again. `no envelope serves` means the event is not open at that time.
- `venue_ready` should show the event ID prefix, the window in Unix seconds next to `nowUnix`, and `receiverState` as verified with result `match`. `UNVERIFIED` with `mismatch` means the signature did not check out. The window is not judged there: phones accept the delivery container from `validFromUnix` through `acceptedThroughUnix`, so check that `nowUnix` lies between those two. `validThroughUnix` runs up to ten minutes past the point where phones stop accepting it; do not use it to decide when to switch.
- The Bluetooth approval and stable signing are the same as in B; see the tool README.
- The same Mac can also run `participate` in a second terminal as an extra participant. This was observed to work once alongside `venue`; it is not guaranteed.

## 4. Check mutual sensing

1. Put the joined devices (two or more iPhones, or iPhones plus a Mac) near each other with Beid in the foreground, and wait a few minutes. Two or more devices are enough to see the detected count rise, but a Record is created and submitted only with four or more participants.
2. On iPhone, the count of detected participants should rise. On the Mac, the JSON log should show lines for detected peers.
3. If nothing is detected, check in this order: every device joined the same event (the Event ID matches), Bluetooth is granted, Beid is in the foreground, and all devices run the same build.

When you report a result, include the device combination, the build number, any error text, and the Mac log if one was used.
