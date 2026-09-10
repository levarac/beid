# Venue bundle import and serving

Scope: beid #432, lane 1. The profile is
[the profile merged into Parallax main](https://github.com/levarac/parallax/blob/e3cc67e7864ea44d3e8502a68e456982f4cde58c/protocol/spec/v0.1/venue-bundle.md).
Its bytes were compared with the implemented profile after merge and match
exactly, including the bounds-before-signature ordering. The maintainer's current
[issue body](https://github.com/thegreeting/beid/issues/432) owns product scope.

## Ownership record

| family | class | current_ios | current_android | ruling_or_invariant | owner | shared_symbol | licensing_test | platform_callers | status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Venue artifact decode | C / INVENT | No venue importer found | No venue importer found | Exact deterministic CBOR bundle and handoff; reject malformed inputs | parallax #69 | VenueBundle / VenueHandoff | VenueBundleCodecTest / VenueBundleBoundsTest / VenueLeaseFixtureTest | iOS file/link import pending; Android adapter deferred to beid #460 | Shared RED/GREEN recorded; native wiring pending |
| Venue import verification | C / INVENT | None | None | Handoff and configured chain coordinates, anchored signed definition, SDK-verified envelopes, full schedule must agree | beid #432 / parallax #69 | VenueBundleImport | VenueBundleImportTest | iOS importer; Android adapter deferred | Design |
| Venue serving schedule | C / INVENT | v1 hint; manually chosen local dates | No venue surface | Serve only one verified, current slice; stop at gaps, expiry or stale registry selection | beid #432 | VenueBundleServing | VenueBundleServingTest | iOS organizer model and dedicated venue engine | Design |

The source survey above covers `ios/Beid`, `android/app/src/main` and
`shared/src/commonMain` at beid `164c7bf9a63e501946a2b313a62e0cd86fc609e9`.
Existing URL handling routes to MetaMask. It is not a venue artifact importer.

## Boundaries

The shared module owns artifact decoding, digest comparison, definition
verification, schedule coverage, registry selection and readiness. It reuses the
existing Parallax definition verifier rather than introducing another one.

Native code owns file access, fetching, Barnard verification, advertising and
lifecycle callbacks. The venue broadcaster continues to own its dedicated
engine. Supplying an own signed container intentionally folds participant relay
(`own_value_precedence`) and replaces the v1 hint.

Successful import does not start advertising. Explicit activation requires a
current eligible slice. Imported bytes and signed validity replace the editable
name and local validity interval. Expiry, failed revalidation and absence of an
eligible slice stop serving; an old envelope is never stretched to fill a gap.

## Dependencies and evidence

Updated scope ruling from subpm-levarac, 2026-09-10: phase 1 proves a **current
lease**, ending no later than `currentEnin + 1`, after real SDK verification at
the current ENIN. It does not claim complete signed schedule coverage. The full
import/schedule rows above describe phase 2 and are not phase-1 completion claims.
The native byte-layout projection is rejected; no spec-122 offsets are copied
into this host. SDK-owned structural metadata (Barnard #203) and verified signed
expiry (Barnard #197) are the selected dependency boundary.

The local lease deadline is not the signed relay expiry. Name it separately in
the shared API and UI so a one-ENIN permission cannot be mistaken for verified
signed-window metadata. The current issue body, fetched on 2026-09-10 at
08:52 UTC, now explicitly records the phase split and pending-pin checkbox.

The branch fast-forwarded to `248742dcfe0b5392988646dcbb55e3e9346e0994` under
operator authorization. Its two-commit delta changes only `AGENTS.md`; the
source inventory above is unchanged. On that base, the codec's null scaffolding
produced exactly the eight preregistered assertion failures: 431 total,
419 passed, eight failed, four known skips, exit 1. Three signed-fixture tests
passed in that run. Two direct constructor-boundary tests and one actual
bundle/handoff fixture-consumption test were added afterward. The fixture tests
initially pinned the signed inputs without exercising the new decoder; only
the added consumption test witnesses that path.

GREEN on the implemented working tree: `python3 scripts/run_local_tests.py
android :shared:testAndroidHostTest :app:compileDebugKotlin`, with explicit
`ANDROID_HOME`, returned exit 0. XML and wrapper summaries agree: 434 total,
430 passed, zero failed, four known skips; Android compile executed. All 20
venue tests executed without a skip. This is shared/Android build evidence,
not native wiring, Swift Export, SDK verification or radio evidence.

Four subsequent one-site mutations removed the constructor count guard,
constructor length guard, constructor input copy, and getter output copy.
Each full shared run produced exactly its preregistered sole failing test:
434 total, 429 passed, one failed, four known skips, exit 1. Source snapshots
were restored after every run; source and working-diff SHA-256 matched their
pre-experiment values. These runs validate the constructor and copy witnesses;
they do not substitute for the future native ownership mutation.

The local run above skipped the Parallax source comparison. CI at `3f5064c`
executed it and failed: this change had incorrectly placed a beid-generated
fixture and a Barnard vector in the directory reserved for pinned Parallax
resources. With a private checkout at the exact `5215991b440db8e8bdc6279eee30affa0c532023`
pin, the full shared suite reproduced the same sole failure: 434 total,
430 passed, one failed, three skipped. All nine pre-existing Parallax resources
matched their pinned blobs; the two newly added files had no such source.

The repair relocates those two files to `src/commonTest/fixtures`, declares that
resource root, and uses the declared roots for both native resource-copy tasks.
The checksum gate and pin are unchanged. Before/after SHA-256 values match, and
fixture regeneration from its new path is byte-identical. With the pin unchanged,
the repaired full shared suite executed 434 tests: 431 passed, zero failed,
three skipped. The exact comparison test passed rather than skipping. The full
Android app suite executed 328 tests, all passed. Android compile was
`UP-TO-DATE`, not a fresh compile. Both native resource-copy tasks ran; their
four previously absent fixture outputs now match their source SHA-256 values.
These are copy checks, not native test execution. The wrapper's two missing-XML
warnings came from treating Copy task names containing `Test` as test tasks;
JUnit separately confirms both real test tasks executed with the counts above.

The remaining three skipped integration tests are
`SepoliaEventRegistryIntegrationTest.readsDemoEventFromLiveReaderAtSafeBlock`,
`LocalAnvilEventRegistryIntegrationTest.readsTheRealReaderFacadeAtAPinnedBlockAndCachesTheResult`,
and `LocalAnvilEventRegistryIntegrationTest.fetchesTheAnchoredSignedDefinitionFromALocalHttpStub`.

Barnard 0.9.0 is now pinned on both hosts through the separate PR #477.
The decoder foundation remains PR #474; identity/SDK/current-lease verification
and iOS acquisition/UI/radio effects are separate follow-ups. Phase 1 retains
its current-lease-only restriction. The public expiry and structural accessor
make phase 2 possible, but neither full schedule verification nor multi-slice
serving is implemented by this foundation. Registry read results
do not themselves carry chain or source-contract coordinates; verification must
bind them to the deployment that produced the read, rather than compare two
untrusted copies of the same addresses.

Existing tests already assert that a v1 hint remains `UNVERIFIED`:
`NearbyEventReceiverStateTest.candidateFromV1HintAloneStaysUnverified` and the
hint-only branch of `NearbyEventReceiverStateAdapterTest.theCardFollowsTheSharedJoinEligibility`.
Their execution was measured on both suites: shared 414 tests (410 passed,
4 skipped), Android 328 passed. Changing the candidate fallback tier from
`UNVERIFIED` to `RADIO_SELF_VERIFIED` caused exactly the four preregistered shared
tests and two Android tests to fail. The source bytes and tracked diff were then
restored exactly. This is a witness for that mutation, not for every possible
receive-path defect.

Verification order:

1. Run the shared and Android covering suites before edits; record executed counts.
2. Mutate the hint-only tier, observe the existing negative assertions fail, and
   restore the exact source snapshot.
3. Add codec, verification and schedule tests, record behavioral RED, implement,
   and run the full covering suites.
4. Pass the emitted container through the coordinator receive path using real
   SDK verification. Include a v1 hint and one-byte signature/content mutations.
5. Build fresh Swift Export and run the covering iOS suite on an erased, named
   simulator UDID, with the host slot granted before launch.

No radio proof is implied by simulator or vector evidence. Android serving is
deliberately deferred to beid #460; shared rules are available for its adapter.

## Decoder-layer witnesses after review

The independent foundation review at `fb1d13a` found the decoder guards were
correct but unwitnessed: the `VenueBundle` constructor repeats the same
bounds, so public decode tests still rejected invalid input after removing the
decoder checks. The reader helper is now internal, not public, and two tests
call it directly without constructing a bundle. They use complete arrays at
counts 0, 1, 512 and 513 and byte lengths 198, 199, 508 and 509. No huge declared
array is constructed; a truncated header would merely witness missing input.

The full shared suite executed 436 tests: 433 passed, zero failed, the three
named external integration tests above skipped. Against the unchanged source
of that successful run, removing only the decoder count guard produced exactly
one failure, `envelopeReaderEnforcesCountBoundsWithoutTheBundleConstructor`.
Removing only its byte-length guard produced exactly one failure,
`envelopeReaderEnforcesByteBoundsWithoutTheBundleConstructor`. Each mutant ran
the full 436-test suite: 432 passed, one failed, three skipped. The Parallax
comparison executed and passed against `6fe165f`
in all three runs. Source and the entire working diff were restored and
hash-checked after each. Baseline source SHA-256:
`26fe63d94fe1ca3b47b80c64fa6dc6716674c9e09e80929ecaacfb07bc8bbe3a`.

The allocation mechanism is REASONED, not experimentally reproduced:
`StrictCborReader.readArrayLength` permits a declaration up to `Int.MAX_VALUE`,
and `List(count)` allocates before reading its elements. A tiny complete CBOR
length declaration therefore need not fit that allocation inside the input
byte cap. The count guard precedes that allocation by construction. These
small direct tests independently witness the guard, not allocation ordering.
The whole-input test was renamed `rejectsOversizeWholeInputs` because its
assertions do not dynamically prove ordering either.

Ordinary reader byte accesses use `readByte`'s bounds check; its eight-byte
unsigned path also peeks the first byte after requiring eight remaining bytes.
Byte/text copies require lengths within the remaining buffer. This source
argument explains rejection through `IllegalArgumentException` rather than an
indexing exception; it is not a claim to have induced memory exhaustion.

The rebase onto main `38ce700` preserved main's new Parallax pin and both
updated digests. Rebase was queue position, not the membership repair: the
experiment establishing that diagnosis ran with the old `5215991` pin unchanged.
