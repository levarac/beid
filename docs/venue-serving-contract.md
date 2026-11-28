# Venue serving interface v1

This is the additive interface between venue verification and the iOS
acquisition, persistence, UI and radio effects. The interface commit contains
types and a test-target fake, not a production verifier or signed broadcaster.
It does not make beid#432 complete. Its tests have not been run at the initial
handoff; the shared host slot is queued. No behavioral RED/GREEN is claimed.

## Ownership

- Foundation PR #474 supplies strict bundle/handoff decode, digest and bounds.
- The verification follow-up owns handoff/deployment/registry-source binding,
  the named anchored signed definition, native SDK envelope verification,
  current-lease eligibility and the final production receive-path proof.
- The iOS follow-up owns file/HTTPS acquisition, bounded reads/redirect policy,
  public artifact storage, organizer UI, the dedicated engine, lifecycle,
  clock-change/expiry handling and startup failures.

The seam is a `VenueServePermit`: these exact bytes may be served until this
exclusive instant. The consumer must not derive event IDs/digests/windows,
choose a slice, extend a deadline or treat fetch/import success as permission.
The existing v1 `VenueDeviceBroadcasting` stays intact. The new effect port is
`VenueSignedContainerBroadcasting`.

## Types and trust

The authoritative declarations are in
`ios/Beid/Sensing/VenueBundleVerification.swift`.

- `VenueBundleVerifying.importBundle` takes the two public byte sequences and
  has no clock parameter. An opaque `VenueImportedBundle` represents identity
  verification, not a presently usable or fully validated envelope schedule.
  Its public source bytes can be stored, but must be imported again on restart.
  The receipt is not Codable and has no public/memberwise initializer.
- A receipt has **no display name**: EventDefinitionV1 does not contain one.
  Only a `VenueServePermit` gets a display name from SDK-verified B005 bytes.
- `evaluate` takes a receipt and `VenueClockReading`. An available reading is
  a numeric clock value, not an independent authentication of device time.
  Future beid#464 preflight can decide when to supply unavailable.
- A permit fixes identity, hop-zero container bytes, payload digest, current
  ENIN and `stopAtUnixSeconds`. Its scope is `currentLeaseOnly`. The consumer
  may format those facts; it must not infer complete signed schedule coverage.
- The two opaque classes can only be constructed in the verification file.
  Debug-only test factories serve the scripted fake and do not exist in
  Release. There is no production construction path in the interface commit.

**Consumers MUST switch exhaustively, with NO default case, over all four
enums: `VenueImportFailure`, `VenueServingBlock`, `VenueRadioState` and
`VenueRadioFailure`.** They are payload-free with compiler-synthesized
`CaseIterable`. Exhaustive switches make additions break the consumer build;
`allCases` separately makes outcome-coverage tests include additions. Neither
control substitutes for the other.

None of the four declares explicit raw values, so **each raw value is its own
camelCase case name** — `handoffMismatch`, `notStarted`. That is load-bearing
for the paragraph below.

### Two spelling conventions in `shared/`, deliberately

`shared/` carries two conventions for outcome codes, and this is a choice with a
stated reason rather than an oversight:

- **snake_case** for identity failure codes — `handoff_mismatch`,
  `registry_unavailable` — in `VenueBundleIdentity.kt`.
- **camelCase, matching the native case names verbatim** — `notStarted`,
  `noCurrentEnvelope` — for the serving block codes in `VenueCurrentLease.kt`.

The serving codes match the native names so outcome-coverage tests are a
mechanical set equality with **no mapping standing between the two sides**. A
mapping authored and also tested by the same person is the shape of test that
cannot fail for the reason it exists, and that is what the first option would
have produced.

Today the two conventions never meet: the identity codes appear only in that one
Kotlin file — no mapping table, no translation function, no native consumer —
which is consistent with there being no production construction path yet. **Item
4 is where a production path first appears, and which convention becomes the
shared vocabulary is deferred to it.**

Two conditions hold until then:

- When item 4 needs a real mapping, **that mapping goes to an independent
  reviewer — one dispatched independently of its author — as a separate
  object**, and is not tested by its author alone.
- **If the identity codes ever need to cross this boundary, raise it** rather
  than normalising one convention into the other in passing. That is the moment
  the deferred question comes due.

Moving payloads into wrappers must not admit contradictory combinations:

- `VenueServingRejection` has a failable initializer. `notStarted` requires a
  nonnegative `recheckAtUnixSeconds`; every other reason requires nil.
- `VenueRadioUpdate` also has a failable initializer. `failed` requires a
  `VenueRadioFailure`; every other state requires nil.
- The invalid pairings are rejected at every construction site, including
  consumer tests. The contract tests enumerate the complete pairing matrix.

## Radio/lifecycle rules

`installAndStart` accepts only a permit. Clear before replacement and clear
again if installation fails. Barnard v0.9.0, commit
`d382de873fa355a7cb21d219b2e33903105e86fa`,
`packages/swift/barnard/Sources/Barnard/BarnardEngine.swift:674-675` explicitly
retains the previous container on rejection. Passing nil at :676-680 clears it.

The same source :1186-1188 calls OS advertising and immediately reports
`advertise_start`/isAdvertising=true. The completion callback at :2163-2168
only reports failure and has no success event. Therefore
`advertisingRequested` is a distinct type case. It must not become
OS-confirmed/on-air through a label change, a delay or absence of an error.
RF success needs separate receiver evidence or an explicit future SDK signal.

The consumer owns request generations. A delayed result may install only if
it belongs to the current request. Clock discontinuity, scene departure,
expiry or replaced input requires clearing. A failed early re-fetch retains
the currently valid envelope and its existing exclusive deadline, with a visible
failure. It grants no extension. At the deadline, clear before awaiting renewal.
A receipt or
permit restored from storage is never authority to resume. A timer handles
an exclusive stop instant; the consumer does not recompute ENIN boundaries.

For iOS 1.1.1 screen 14b, a valid load settles at `ready`, showing the
SDK-checked event name, registrar from the verified definition and loaded pack
digest. Only the explicit Start action installs the checked permit; starting
within its interval requires no acquisition or registry request. Foregrounding
or loading a replacement cannot supply that first confirmation.

Screen 14b shows three times (checked 2026-11-28 against `release/1.1.0`
`d7d97258`, `VenueSignedServingView`):

- While a pack is ready or serving, `Until` is the current permit's exclusive
  stop instant, and `Remaining` counts down to that same instant once a second.
  Both rows describe the current permit. A later lease in the loaded pack can
  be installed only after a new serving evaluation.
- `Pack schedule ends` is the end of the imported complete schedule
  (`broadcastUntilUnixSeconds`). It appears only while ready or serving, and
  only when it is later than `Until`.
- With a pack loaded but neither ready nor serving, for example after the lease
  ended, `Until` shows the loaded schedule's end beside the pack digest.

Two different things happen at a deadline:

- Next lease inside the loaded signed chain. When a permit reaches its
  exclusive stop and the loaded chain continues, the radio is cleared and the
  next lease is re-evaluated from the bundle already held. No bundle or
  handoff is re-fetched; the registry is consulted as in any evaluation.
- Renewing the chain. When a source is recorded, re-fetch that exact source
  60 seconds before the chain ends and again at its end. A candidate must pass
  identity, signatures and current-lease checks before it replaces the loaded
  chain. A saved pack without a recorded source is not re-fetched: at the
  chain's end the radio is cleared and broadcasting stays stopped until a
  current pack is supplied.

A link's fragment remains pinned to its handoff digest: a republished bundle
with another digest needs a matching handoff, and a fragment link cannot
discover that new handoff by itself. The paired-URL acquisition path re-fetches
both public artifacts. No path synthesizes a handoff or weakens digest
agreement to make renewal succeed.

### Manual re-Supply after a failed refresh (iOS)

1. `Pack refresh failed` while broadcasting means the current lease continues
   only until the `Until` time. Ask the organizer for a current pack.
2. When the chain ends, the radio is cleared before the refetch. If the refetch
   fails, the screen shows `Lease ended` and "The lease ended and the pack could
   not be refreshed. Broadcasting stopped. Load a current pack."
3. Supply the organizer's current link in one of two ways:
   - Paste the link and press `Use this link`.
   - Use `Scan QR code`. A successful scan loads the pack at once, without
     `Use this link`.

   On `release/1.1.0` no screen control calls the two-URL supply
   (`supply(bundleSource:handoffSource:)` or `supplyConfigured`); only tests
   do, so on a device the link is the manual path. A link stays pinned to its
   handoff digest, so it needs the organizer's new link after a republish.
4. Check the event ID, registrar and pack digest. The pack settles at `ready`;
   press `Start broadcasting`. A replacement never starts without this action.
5. `Load saved pack` re-verifies the saved bytes and cannot restart an ended
   chain. While broadcasting, `Check for pack update` refetches the recorded
   source; "No newer pack is available." means the same digest verified again.

### Refresh diagnostics

The view model logs to the unified log, subsystem `org.levarac.beid`,
category `venue-refresh`:

- `venue_refresh failed trigger=<scheduled|expiry|recovery|manual>
  stage=<source|acquisition|import|event_match|evaluation> category=<name>`.
  The category is the raw value of `VenueAcquisitionFailure`,
  `VenueImportFailure` or `VenueServingBlock`, or `noUpdateSource` or
  `anotherEvent`.
- `venue_serving stopped_at_expiry chain_ended=<true|false>
  refresh_source=<true|false>` when a serving permit reaches its exclusive stop
  and is cleared. A prepared permit that never passed Start is not logged,
  because nothing was broadcasting. With `chain_ended=false` the next lease is
  re-evaluated from the loaded chain without a fetch. With `chain_ended=true`,
  the recorded source is re-fetched to renew the chain when a source is
  recorded (`refresh_source=true`). With `refresh_source=false` nothing is
  fetched, no `venue_refresh failed` line follows, and broadcasting stays
  stopped.
- `noUpdateSource` (stage `source`, trigger `manual`) is logged only when the
  operator presses `Check for pack update` while serving a pack that has no
  recorded source.

No URL, key, event ID, digest, display name or payload byte is logged. Read it
with `log stream --predicate 'subsystem == "org.levarac.beid" AND category ==
"venue-refresh"'`, or with Console on a connected device.

This update covers the native iOS venue-broadcast flow. Android's existing
`VenueController` owns its platform lifecycle and renewal effects; attendee
reception and the removed unsigned venue-device/key routes are out of scope.

## One fake, including failures

`ScriptedVenuePorts` in BeidTests implements both ports. It queues immediate or
deferred verification replies, permits completions in either order, queues an
install failure and delivers explicit radio updates. Its ordered call log
records input bytes/clock, installed bytes/deadline and every clear. An
unscripted call records an XCTest failure instead of silently becoming happy.
Installing bytes does not itself emit a radio success. A failed replacement
deliberately retains previous bytes until the consumer clears them.

The consumer must exercise all these scenarios against its real view model:

1. Each import rejection: malformed/bounds, handoff mismatch, unsupported
   deployment, registry unavailable/wrong source, absent anchor, bad definition.
2. Identity imported but not evaluated: no install or ready/coverage claim.
3. Delayed import/evaluation finishing after a newer request or cancellation.
4. Each serving rejection: unavailable clock, future event, expiry, no current
   envelope, bad SDK envelope, stale definition and unavailable registry.
5. A current lease followed by expiry or a different current definition.
6. Backward/forward clock jumps, jumping over the whole lease, and foreground
   return with an old async completion still pending.
7. Installation rejection after an earlier successful install: verify the
   clear-before-replace and clear-again-on-failure order.
8. Bluetooth waiting/unavailable, advertise failure and GATT startup failure.
9. Advertising requested and then stopped, without inventing confirmation.
10. Public bytes restored from storage but corrupt or requiring offline
    registry verification: re-import/refuse, never restore a permit.

## Executable correspondence and evidence

`VenueServingPortContractTests` tests the type pairing invariants and fake.
`VenueServingContractFixture` loads the single JSON under
`shared/src/commonTest/fixtures/vectors/positive/venue-current-lease-v1.json`,
copied into the native test bundle by XcodeGen. Its source SHA and literal
expected identity/digests/current ENIN/exclusive stop instant are fixed; the
deadline assertion does not refer to a production constant.

Lease refresh over one Bundle/Handoff URL pair (beid#589) runs the real signed
full-schedule pack, a chain of 300-second leases, through
`ProductionVenueBundleVerifier` and the recorded registry:
`ProductionVenueBundleVerifierTests.testSignedLeasesFromOnePairedSourceContinueThenStopAtChainEndWithDiagnostics`
covers the next lease taking over, a manual and a failed scheduled refetch, the
stop at the chain's end and a refused re-Supply of the ended chain, and
`testStopAtLeaseEndRecoversThroughManualResupplyFromTheSamePair` covers recovery
after a stop. The repository holds one real signed pack, so adopting a newer
pack from the same pair uses the scripted ports:
`VenueSignedServingViewModelTests.testFailedRefreshStopsAtExpiryAndManualResupplyFromSamePairAdoptsNewerPack`.

`assertVenueOutcomeCoverage` accepts **observed** outcome sets and compares
them to synthesized `allCases`. The real verification provider must exercise
all import/serving cases, and the real native effect adapter all radio cases.
Their combined observed sets and the fake's observed sets must be equal to
the same enum inventory. Passing the fake test does not prove that equality
for the real providers. That production correspondence is still owed before
the verification/effects follow-ups complete.

The two follow-ups use the same artifact for provider and consumer tests. The
provider side uses real SDK verification; the consumer side uses the scripted
ports and verifies the real view model's ordered effects and visible states.
The final integration installs a real permit through the real broadcaster,
takes the actual Barnard-engine bytes through SDK verification and beid's
production receive adapter, and requires recordVerifiedEnvelope to reach
RADIO_SELF_VERIFIED. v1-only input and one changed signed byte are the negative
controls. No fake verifier or manually constructed trust tier proves this.

Both sides run the full covering suites through `scripts/run_local_tests.py`:
shared Android-host tests with PARALLAX_REPO at the current pin, plus full
BeidTests/BeidUITests on a concrete freshly erased Simulator. A named test must
be present, executed and non-skipped; empty tasks or resource copies are not
test success. RF/two-device evidence is a separate claim.

## Later consumers

The CLI uses the public bundle/handoff format and gains no app signing-key
API. Phase2 changes the provider's all-slice verification/selection, not the
consumer's ability to issue permits. A broader verification scope is added
only with proof. Participant relay (#475) keeps its own lifecycle. Clock
preflight (#464), safe diagnostics (#466) and policy stops (#467) consume
these bounded facts without making the UI reimplement protocol decisions.
