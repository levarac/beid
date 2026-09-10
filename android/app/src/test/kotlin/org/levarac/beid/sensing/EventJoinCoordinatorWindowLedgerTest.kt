package org.levarac.beid.sensing

import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertTrue
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.levarac.beid.persistence.BindingRecordStore
import org.levarac.beid.persistence.SelfProofRecordStore
import org.levarac.beid.persistence.UnsentWindowLedgerStore
import org.levarac.beid.persistence.WindowObservationDraftStore
import org.levarac.beid.shared.report.createUnsentWindowObservationRecoveryInput
import org.levarac.beid.shared.report.reconcileUnsentWindowLedgerAfterRelaunch

/**
 * Window bookkeeping around the join gate (beid#374).
 *
 * ## Two tests moved to `shared/`, and what that costs here
 *
 * `joiningAnotherEventClosesTheOpenWindowBeforeAcceptingItsDetections` and
 * `replacementCoordinatorContinuesAndClosesTheSameWindowExactlyOnce` used to
 * live here and now live in `shared/`'s observation suite. They asserted on
 * the *signed* observation structure, and that assertion cannot be made in
 * this module any more.
 *
 * The reason is worth stating exactly, because it is not fixture sloppiness.
 * Their canned signature verified because THE OLD CONTEXT WAS THE CONFORMANCE
 * VECTOR'S CONTEXT — same window id, event id, definition digest, observer
 * key, `finalizedAt`, ENIN and participant commitment. The join gate now
 * sources event identity from barnard's B005 vector instead, so that structure
 * is UNREACHABLE BY CONSTRUCTION: no arrangement of fixture values is both the
 * observation vector's context and a promoted candidate. And the window never
 * closes without a signature that verifies — `signWithCompactSignatureHex`
 * throws and nothing catches it — so substituting ledger assertions here was
 * not an option either; they sit downstream of the throw.
 *
 * **The residual coverage gap, stated rather than left as an absence:** before
 * this change, `signatureStructureHex` appeared in exactly two tests in the
 * whole app test module — those two — and
 * [WindowObservationAccumulatorTest] never asserted that a context's
 * `eventIdHex` or definition digest reach the signed structure. After the
 * move, `shared/` covers accumulator-input to signed-structure, and the shared
 * issuer suite covers the capability carrying the right digest. What nothing
 * covers is the step BETWEEN them: [EventJoinCoordinator] building a
 * [WindowObservationContext] out of the capability. That link is uncovered and
 * is filed as a follow-up rather than pretended away.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class EventJoinCoordinatorWindowLedgerTest {
    /**
     * The link the moved tests used to cover, recovered here without a signer.
     *
     * [FakeSensingCryptography] appends its [FakeSensingCryptography.Call.SignWindowReport]
     * record BEFORE the observation layer verifies the signature it returns, so
     * the bytes the host actually asked to have signed are observable even
     * though the canned signature cannot verify for this structure. The verify
     * failure is therefore expected and deliberately swallowed: this test is
     * about what reached the signer, not about the signature coming back.
     */
    @Test
    fun theJoinedEventIdentityReachesTheBytesTheHostSigns() = runTest {
        val directory = Files.createTempDirectory("window-signed-identity").toFile()
        val owner = WindowObservationRuntimeOwner(
            newWindowId = { java.util.UUID.fromString("00112233-4455-6677-8899-aabbccddeeff") },
            ledgerInstanceId = { "000102030405060708090a0b0c0d0e0f" },
        )
        val cryptography = vectorCryptography()
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, directory, owner, cryptography, registry)
        joinPromotedVectorEvent(coordinator, engine, registry, DEFINITION_A, BLOCK_A)
        emitRecordingWindow(engine)

        // The canned signature cannot verify for a structure the conformance
        // vector was not signed over. Everything this test asserts happened
        // before that point.
        runCatching { coordinator.leaveEvent() }

        val sign = cryptography.calls
            .filterIsInstance<FakeSensingCryptography.Call.SignWindowReport>()
            .single()
        assertEquals(NearbyEventPromotionFixture.EVENT_ID_HEX, sign.eventCode)
        val signatureStructureHex = sign.bytes.toHexString()
        assertTrue(
            NearbyEventPromotionFixture.EVENT_ID_HEX in signatureStructureHex,
            "the joined event's canonical id must reach the bytes the host signs",
        )
        assertTrue(
            DEFINITION_A in signatureStructureHex,
            "the definition digest the capability carried must reach those bytes too",
        )
        // No absence assertion here on purpose: only DEFINITION_A is ever
        // joined in this test, so asserting DEFINITION_B's absence could not
        // fail. The falsifiable form of that property lives in
        // WindowObservationAccumulatorTest.beginningASecondEventClosesTheFirstEventsOpenWindow,
        // where a second event genuinely exists.
    }

    @Test
    fun aDisposedCoordinatorsLateLookupAnswerNeverReachesADefinitionRead() = runTest {
        val directory = Files.createTempDirectory("window-late-context").toFile()
        val owner = WindowObservationRuntimeOwner(
            newWindowId = { java.util.UUID.fromString("00112233-4455-6677-8899-aabbccddeeff") },
            ledgerInstanceId = { "000102030405060708090a0b0c0d0e0f" },
        )
        val cryptography = vectorCryptography()
        val firstEngine = FakeEventJoinEngine()
        // The first coordinator's registry read never answers before the
        // coordinator that asked for it is destroyed, which is the only way its
        // answer can arrive late enough to collide with a replacement.
        val firstRegistry = FakeNearbyEventRegistry()
        val first = coordinator(firstEngine, directory, owner, cryptography, firstRegistry)
        firstEngine.emitVerifiedEnvelopeV2(
            "peripheral-vector",
            NearbyEventPromotionFixture.CONTAINER,
            NearbyEventPromotionFixture.ENIN,
        )
        runCurrent()

        first.dispose()

        val replacementEngine = FakeEventJoinEngine()
        val replacementRegistry = FakeNearbyEventRegistry()
        val replacement = coordinator(replacementEngine, directory, owner, cryptography, replacementRegistry)
        joinPromotedVectorEvent(replacement, replacementEngine, replacementRegistry, DEFINITION_B, BLOCK_B)

        // The dead coordinator's registry finally answers. Disposal advanced
        // its callback generation, so the answer is discarded before it can
        // reach any shared runtime state -- and the proof of that is that no
        // definition read is ever started for it, which is what makes the
        // second completion below impossible rather than merely ignored.
        firstRegistry.completeLookup(NearbyEventIdLookup(true, NearbyEventPromotionFixture.EVENT_ID_HEX, null))
        runCurrent()
        assertFailsWith<IllegalArgumentException>(
            "a disposed coordinator must not carry its lookup answer into a definition read",
        ) {
            firstRegistry.completeDefinition(NearbyEventPromotionFixture.definition(DEFINITION_A, BLOCK_A))
        }

        assertEquals(
            NearbyEventPromotionFixture.EVENT_ID_HEX,
            replacementEngine.getCurrentEventCode(),
            "the replacement's session is untouched by the dead coordinator's late answer",
        )
        assertIs<EventJoinUiState.Sensing>(
            replacement.state.value,
            "and it is still the live session, not one the late answer disturbed",
        )
    }

    @Test
    fun configurationDestroyDoesNotCloseTheBusinessWindow() = runTest {
        val directory = Files.createTempDirectory("window-config-destroy").toFile()
        val ledgerFile = directory.resolve("ledger.snapshot")
        val accumulator = WindowObservationAccumulator(
            context = { WindowObservationContext("event", "21".repeat(32), "22".repeat(32), "ab".repeat(32)) },
            cryptography = FakeSensingCryptography(
                eventSigningPublicKeyResult = PUBLIC_KEY.chunked(2).map { it.toInt(16).toByte() }.toByteArray(),
                signWindowReportResult = SensingRecoverableSignature(
                    SIGNATURE_R.chunked(2).map { it.toInt(16).toByte() }.toByteArray(),
                    SIGNATURE_S.chunked(2).map { it.toInt(16).toByte() }.toByteArray(),
                    0,
                ),
            ),
            ledgerStore = UnsentWindowLedgerStore(ledgerFile),
            draftStore = WindowObservationDraftStore(directory.resolve("draft.snapshot")),
            observationDirectory = directory.resolve("observations"),
            nowEpochSeconds = { 1_800_000_000.0 },
            newWindowId = { java.util.UUID.fromString("00112233-4455-6677-8899-aabbccddeeff") },
            ledgerInstanceId = { "000102030405060708090a0b0c0d0e0f" },
        )
        accumulator.observe(6_000_000, RPID_TWO, REPORTER_RPID, recording = false)
        accumulator.observe(6_000_000, RPID_ONE, REPORTER_RPID, recording = true)
        val engine = FakeEventJoinEngine()
        val coordinator = EventJoinCoordinator(
            engine = engine, nowEpochMillis = { testScheduler.currentTime }, coroutineScope = backgroundScope,
            sensingCryptography = FakeSensingCryptography(),
            selfProofRecordStore = SelfProofRecordStore(newTempRecordFile("self-proofs")),
            bindingRecordStore = BindingRecordStore(newTempRecordFile("binding-records")),
            injectedWindowAccumulator = accumulator,
        )

        coordinator.dispose()

        assertEquals(1L, UnsentWindowLedgerStore(ledgerFile).load()?.persistenceRevision)
        assertEquals(0, directory.resolve("observations").listFiles().orEmpty().size)
    }

    /**
     * The observation context now arrives with the join itself (beid#374), so
     * the identity a coordinator will sign under is chosen here, through the
     * registry answer it gets, rather than fed in afterwards.
     */
    private fun kotlinx.coroutines.test.TestScope.coordinator(
        engine: FakeEventJoinEngine,
        directory: java.io.File,
        owner: WindowObservationRuntimeOwner,
        cryptography: FakeSensingCryptography = vectorCryptography(),
        nearbyRegistry: FakeNearbyEventRegistry = FakeNearbyEventRegistry(),
    ): EventJoinCoordinator = EventJoinCoordinator(
        engine = engine,
        nearbyRegistry = nearbyRegistry,
        nowEpochMillis = { NearbyEventPromotionFixture.VECTOR_NOW_EPOCH_MILLIS },
        coroutineScope = backgroundScope,
        sensingCryptography = cryptography,
        selfProofRecordStore = SelfProofRecordStore(newTempRecordFile("self-proofs")),
        bindingRecordStore = BindingRecordStore(newTempRecordFile("binding-records")),
        ledgerFilesDir = directory,
        windowObservationRuntimeOwner = owner,
    )

    private fun emitRecordingWindow(engine: FakeEventJoinEngine) {
        engine.emitDetection(6_000_000, RPID_ONE, "device-1", REPORTER_RPID)
        engine.emitDetection(6_000_000, RPID_TWO, "device-2", REPORTER_RPID)
        engine.emitDetection(6_000_000, RPID_ONE, "device-3", REPORTER_RPID)
    }

    private fun vectorCryptography(): FakeSensingCryptography = FakeSensingCryptography(
        eventSigningPublicKeyResult = PUBLIC_KEY.chunked(2).map { it.toInt(16).toByte() }.toByteArray(),
        signWindowReportResult = SensingRecoverableSignature(
            SIGNATURE_R.chunked(2).map { it.toInt(16).toByte() }.toByteArray(),
            SIGNATURE_S.chunked(2).map { it.toInt(16).toByte() }.toByteArray(),
            0,
        ),
    )

    private companion object {
        const val PUBLIC_KEY = "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
        const val REPORTER_RPID = "0110101010101010101010101010101010"
        const val RPID_ONE = "0111111111111111111111111111111111"
        const val RPID_TWO = "0122222222222222222222222222222222"
        const val RPID_THREE = "0133333333333333333333333333333333"
        const val SIGNATURE_R = "d9b39668ed2e92db7226461f059a1ecd06a732bd5bfdae0b23d43390a8025349"
        const val SIGNATURE_S = "462b3ecfaa8305881ad1a8b8960e9f3f1e6770683e0c178543613de942c8b765"
        val DEFINITION_A = "a1".repeat(32)
        val DEFINITION_B = "b2".repeat(32)
        val BLOCK_A = "a3".repeat(32)
        val BLOCK_B = "b4".repeat(32)
    }
}

private fun ByteArray.toHexString(): String = joinToString("") { "%02x".format(it.toInt() and 0xff) }
