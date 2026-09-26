# Local operator submission tests

The normal iOS suite runs a hermetic operator integration test with an
in-process loopback HTTP server. It drives the real `SensingCoordinator` close
path, captures the RPID set before the coordinator clears it, signs and stores
the exact Observation bytes, submits those same bytes, and stores the verified
AcceptanceReceipt. The same suite also proves the inactive-by-default flag,
the durable `SUBMITTING` crash boundary (lookup before any replay POST), and
rejection of a receipt signed by a key outside the verified Event Definition.

Set `BEID_REPO` and `PARALLAX_REPO` to your local checkouts. Select a concrete
available Simulator from `xcrun simctl list devices available` and set
`SIMULATOR_UDID` before running the commands below.

Run the normal integration suite with the required exact simulator destination:

```sh
cd "$BEID_REPO"
xcodebuild -project ios/Beid.xcodeproj -scheme Beid -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  test -only-testing:BeidTests/ReportSubmissionOperatorIntegrationTests
```

The reference-operator integration test remains opt-in. Without
`BEID_RUN_OPERATOR_SUBMISSION_TEST=1` it reports an explicit skip and never
opens a network connection. It creates a real close-window-shaped Observation
with the Barnard event signing key, submits the exact signed COSE bytes, and
requires a verified AcceptanceReceipt.

The current reference-operator checkout does not contain the
`scripts/operator-canary.sh` path mentioned by the original integration brief.
Use the repository's documented local Worker commands below; they exercise the
same `POST /v1/observations` and receipt response contract.

From the Parallax checkout, install dependencies once and start the local
Worker:

```sh
cd "$PARALLAX_REPO"
npm ci
cd operator
npm run d1:migrate:local
npm run workers:dev
```

Before starting Wrangler, create the ignored `operator/.dev.vars` file with a
development-only 32-byte operator signing key. Keep the key local; do not put
it in this repository, shell history, or test output. The operator listens on
`http://127.0.0.1:8787` in the default Wrangler configuration.

Run only the opt-in test from the beid checkout. The public key is the
operator's compressed public key, while the event identity and definition
digest must be the values selected by the Event Definition used for the test:

```sh
cd "$BEID_REPO"
BEID_RUN_OPERATOR_SUBMISSION_TEST=1 \
BEID_OPERATOR_SUBMISSION_ENDPOINT=http://127.0.0.1:8787 \
BEID_OPERATOR_RECEIPT_PUBLIC_KEY=<operator-compressed-public-key-hex> \
BEID_EVENT_ID=<event-id-32-byte-hex> \
BEID_EVENT_DEFINITION_DIGEST=<definition-digest-32-byte-hex> \
xcodebuild -project ios/Beid.xcodeproj -scheme Beid -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  test -only-testing:BeidTests/ReportSubmissionOperatorIntegrationTests
```

The integration-only loopback exception is compiled into Debug tests and is
not enabled in Release. Production submission still requires an HTTPS
endpoint selected by the Event Definition projection.
