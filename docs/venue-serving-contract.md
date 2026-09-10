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
expiry, replaced input or failed refresh requires clearing. A receipt or
permit restored from storage is never authority to resume. A timer handles
an exclusive stop instant; the consumer does not recompute ENIN boundaries.

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
