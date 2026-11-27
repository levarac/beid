package org.levarac.beid.sensing

import java.io.File
import java.nio.file.Files
import java.util.UUID
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.levarac.beid.persistence.BindingRecordStore
import org.levarac.beid.persistence.ProofRecordStore
import org.levarac.beid.persistence.SelfProofRecordStore
import org.levarac.beid.persistence.SessionAggregateSnapshotStore
import org.levarac.beid.persistence.SigilPresenceStore
import org.levarac.beid.wireProofRecording
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/**
 * beid#722: Android records, persists and exposes per-record Sigil presence
 * exactly as iOS #653 does, through the shared codec only. Mirrors iOS
 * `SigilPresenceNeverLeavesDeviceTests` and the `SensingCoordinator` wiring
 * (`topUpSigilPresenceTokens`, `persistSigilPresenceIfNeeded`,
 * `resetSessionState`, `liveSigilInput`, `sigilInput(forProofId:)`).
 */
@OptIn(ExperimentalCoroutinesApi::class)
class EventJoinCoordinatorSigilPresenceTest {
    /** Tokens 1, 2, 3, ... as 32 hex characters: deterministic, so texts are literals. */
    private class SequentialTokens(start: Int = 1) : SigilPresenceTokenSource {
        var next = start
        val drawn = mutableListOf<String>()
        override fun nextToken(): String = next++.toString(16).padStart(32, '0').also { drawn += it }
    }

    private fun token(n: Int) = n.toString(16).padStart(32, '0')

    private val directory: File = Files.createTempDirectory("sigil-presence-coordinator").toFile()
    private val presenceFile = SigilPresenceStore.defaultFile(File(directory, "no_backup"))

    /** Three distinct peers over windows 1..3 (reaches Recording), then one repeat in window 2. */
    private fun recordSession(engine: FakeEventJoinEngine, rpidPrefix: String = "r") {
        engine.emitDetection(enin = 1, rpid = "${rpidPrefix}1", detectedDisplayId = "D0000001")
        engine.emitDetection(enin = 2, rpid = "${rpidPrefix}2", detectedDisplayId = "d0000002")
        engine.emitDetection(enin = 3, rpid = "${rpidPrefix}3", detectedDisplayId = "d0000003")
        engine.emitDetection(enin = 2, rpid = "${rpidPrefix}4", detectedDisplayId = "d0000001")
        engine.emitDetection(enin = 3, rpid = "${rpidPrefix}5", detectedDisplayId = null)
    }

    // Hand-derived from the shared v1 layout (issue-653-design.md section 1.3):
    // D0000001 normalizes to d0000001 and is seen first (token 1) in windows
    // 1 and 2 -> ranks 0,1; d0000002 (token 2) in window 2 -> rank 1;
    // d0000003 (token 3) in window 3 -> rank 2. The id-less observation adds
    // no peer but its window still counts.
    private val sessionText =
        "beid-sigil-presence\t1\nwindows\t3\npeers\t3\n" +
            "peer\t${token(1)}\t0,1\n" +
            "peer\t${token(2)}\t1\n" +
            "peer\t${token(3)}\t2\nend\n"

    @Test
    fun aGracefulSessionEndStoresOneRowThatReloadsByteIdentically() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val store = SigilPresenceStore(presenceFile)
        val snapshots = SessionAggregateSnapshotStore(newTempRecordFile("aggregate-snapshots"))
        val coordinator = coordinator(engine, registry, store = store, snapshots = snapshots)
        val proofIds = mutableListOf<UUID>()
        coordinator.onProofCollected = { id, _, _ -> proofIds += id }

        joinPromotedVectorEvent(coordinator, engine, registry)
        recordSession(engine)
        val proofId = proofIds.single()
        coordinator.leaveEvent()

        assertEquals(sessionText, store.records.single().presenceText)
        assertEquals(proofId, store.records.single().proofId)
        val reloaded = SigilPresenceStore(presenceFile)
        assertEquals(sessionText, reloaded.records.single().presenceText)
        val input = assertNotNull(coordinator.sigilInput(proofId))
        assertEquals(3, input.windowCount)
        assertSame(input, coordinator.sigilInput(proofId), "memoized per proofId")
        // The drawn peers are the snapshot's deviceCount and the rings its windowCount.
        val aggregate = assertNotNull(snapshots.snapshot(proofId))
        assertEquals(3, aggregate.deviceCount)
        assertEquals(aggregate.windowCount, input.windowCount)

        coordinator.dispose()
        assertEquals(1, SigilPresenceStore(presenceFile).records.size, "a second teardown writes nothing more")
    }

    @Test
    fun theLiveInputExistsOnlyWhileARecordIsInProgress() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, registry, store = SigilPresenceStore(presenceFile))

        assertNull(coordinator.liveSigilInput(), "no session")
        joinPromotedVectorEvent(coordinator, engine, registry)
        engine.emitDetection(enin = 1, rpid = "r1", detectedDisplayId = "d0000001")
        assertNull(coordinator.liveSigilInput(), "no Proof yet, like iOS's activeProofId gate")
        recordSession(engine)
        val live = assertNotNull(coordinator.liveSigilInput())
        assertEquals(3, live.windowCount)

        coordinator.leaveEvent()
        assertNull(coordinator.liveSigilInput(), "the session object is dropped on reset")
    }

    @Test
    fun aSessionThatNeverReachedRecordingStoresNothing() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val store = SigilPresenceStore(presenceFile)
        val coordinator = coordinator(engine, registry, store = store)

        joinPromotedVectorEvent(coordinator, engine, registry)
        engine.emitDetection(enin = 1, rpid = "r1", detectedDisplayId = "d0000001")
        coordinator.leaveEvent()

        assertTrue(store.records.isEmpty())
        assertFalse(presenceFile.exists())
    }

    @Test
    fun theNextSessionOfTheSameDevicesGetsFreshTokens() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val store = SigilPresenceStore(presenceFile)
        val tokens = SequentialTokens()
        val coordinator = coordinator(engine, registry, store = store, tokens = tokens)

        joinPromotedVectorEvent(coordinator, engine, registry)
        recordSession(engine)
        coordinator.leaveEvent()
        joinPromotedVectorEvent(coordinator, engine, registry)
        recordSession(engine, rpidPrefix = "s")
        coordinator.leaveEvent()

        val (first, second) = store.records.map { it.presenceText }
        assertEquals(sessionText, first)
        assertEquals(
            "beid-sigil-presence\t1\nwindows\t3\npeers\t3\n" +
                "peer\t${token(4)}\t0,1\n" +
                "peer\t${token(5)}\t1\n" +
                "peer\t${token(6)}\t2\nend\n",
            second,
        )
        assertEquals(6, tokens.drawn.size, "one CSPRNG draw per new peer, none per repeat")
    }

    @Test
    fun aFailedDrawIsRetriedOnTheNextObservation() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val store = SigilPresenceStore(presenceFile)
        val sequential = SequentialTokens()
        var failNext = true
        val flaky = SigilPresenceTokenSource {
            if (failNext) {
                failNext = false
                null
            } else {
                sequential.nextToken()
            }
        }
        val coordinator = coordinator(engine, registry, store = store, tokens = flaky)

        joinPromotedVectorEvent(coordinator, engine, registry)
        recordSession(engine)
        coordinator.leaveEvent()

        assertEquals(sessionText, store.records.single().presenceText)
    }

    @Test
    fun aSourceThatNeverDrawsWritesNothingAndLogsNoPayload() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val store = SigilPresenceStore(presenceFile)
        val diagnostics = mutableListOf<String>()
        val coordinator = coordinator(
            engine, registry, store = store, tokens = { null }, diagnostics = { diagnostics += it },
        )
        val proofIds = mutableListOf<UUID>()
        coordinator.onProofCollected = { id, _, _ -> proofIds += id }

        joinPromotedVectorEvent(coordinator, engine, registry)
        recordSession(engine)
        assertNull(coordinator.liveSigilInput())
        coordinator.leaveEvent()

        assertTrue(store.records.isEmpty(), "missing_token: the record keeps its neutral ring")
        assertNull(coordinator.sigilInput(proofIds.single()))
        val line = diagnostics.single { it.startsWith("sigil_presence_") }
        assertEquals("sigil_presence_persist_failed reason=UNENCODABLE", line)
    }

    @Test
    fun aKilledSessionStoresNoPresenceEvenWhenRecoveryWritesTheSnapshot() = runTest {
        val owner = SessionCheckpointRuntimeOwner()
        val records = owner.proofRecordStore(ProofRecordStore.defaultFile(directory))
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val store = SigilPresenceStore(presenceFile)
        val live = ledgerCoordinator(owner, engine, registry, store)
        wireProofRecording(live, ProofRecordingBridge(records))
        val proofIds = mutableListOf<UUID>()
        val forward = live.onProofCollected
        live.onProofCollected = { id, session, peers -> proofIds += id; forward?.invoke(id, session, peers) }
        joinPromotedVectorEvent(live, engine, registry)
        recordSession(engine)
        runCurrent()
        advanceTimeBy(1_000)
        runCurrent()
        // The process dies here: no leaveEvent, no dispose.
        engine.onEvent = null
        simulateCheckpointProcessDeath(directory)

        val recovery = ledgerCoordinator(owner, FakeEventJoinEngine(), FakeNearbyEventRegistry(), SigilPresenceStore(presenceFile))
        wireProofRecording(recovery, ProofRecordingBridge(records))
        recovery.drainPendingSubmissionsOnForeground()
        runCurrent()
        try {
            val proofId = proofIds.single()
            assertNotNull(
                SessionAggregateSnapshotStore(SessionAggregateSnapshotStore.defaultFile(directory)).snapshot(proofId),
                "precondition: Android recovery does write the count snapshot",
            )
            assertTrue(SigilPresenceStore(presenceFile).records.isEmpty(), "the in-memory token map died with the process")
            assertNull(recovery.sigilInput(proofId))
        } finally {
            recovery.dispose()
        }
    }

    @Test
    fun presenceTokensAndDisplayIdsReachNoOtherFileAndNoDiagnosticLine() = runTest {
        val owner = SessionCheckpointRuntimeOwner()
        val records = owner.proofRecordStore(ProofRecordStore.defaultFile(directory))
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val store = SigilPresenceStore(presenceFile)
        val diagnostics = mutableListOf<String>()
        // Distinctive tokens, so an accidental occurrence cannot be a coincidence.
        val tokens = ArrayDeque(listOf("5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a01", "5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a02", "5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a03"))
        val coordinator = ledgerCoordinator(
            owner, engine, registry, store, tokens = { tokens.removeFirstOrNull() }, diagnostics = { diagnostics += it },
        )
        wireProofRecording(coordinator, ProofRecordingBridge(records))
        joinPromotedVectorEvent(coordinator, engine, registry)
        val displayIds = listOf("c0ffee01", "c0ffee02", "c0ffee03")
        displayIds.forEachIndexed { index, id ->
            engine.emitDetection(enin = 40L + index, rpid = "77${index}", detectedDisplayId = id, rssi = -61)
        }
        coordinator.leaveEvent()
        coordinator.dispose()
        runCurrent()

        // Positive anchor: the row exists and holds exactly the supplied tokens.
        val text = store.records.single().presenceText
        val probes = listOf("5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a01", "5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a02", "5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a03")
        probes.forEach { assertTrue(text.contains(it)) }
        displayIds.forEach { assertFalse(text.contains(it), "the presence file must not carry a display id") }

        val otherFiles = directory.walkTopDown()
            .filter { it.isFile && !it.canonicalPath.startsWith(presenceFile.parentFile.canonicalPath) }
            .toList()
        assertTrue(otherFiles.isNotEmpty(), "precondition: the session wrote its other artifacts")
        for (file in otherFiles) {
            val bytes = file.readBytes()
            val asText = String(bytes, Charsets.UTF_8).lowercase()
            val asHex = bytes.joinToString("") { "%02x".format(it.toInt() and 0xff) }
            for (value in probes + displayIds) {
                val utf8Hex = value.encodeToByteArray().joinToString("") { "%02x".format(it.toInt() and 0xff) }
                assertFalse(asText.contains(value), "${file.name} carries $value")
                assertFalse(asHex.contains(utf8Hex), "${file.name} carries $value as UTF-8 bytes")
            }
        }
        for (line in diagnostics) {
            (probes + displayIds).forEach { assertFalse(line.lowercase().contains(it), "diagnostic line carries $it: $line") }
        }
    }

    @Test
    fun theDeviceStoreWithoutAStoreStillDrawsLiveButStoresNothing() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, registry, store = null)
        val proofIds = mutableListOf<UUID>()
        coordinator.onProofCollected = { id, _, _ -> proofIds += id }
        joinPromotedVectorEvent(coordinator, engine, registry)
        recordSession(engine)
        assertNotNull(coordinator.liveSigilInput())
        coordinator.leaveEvent()
        assertNull(coordinator.sigilInput(proofIds.single()))
    }

    // MARK: - Radar feed (display only)

    @Test
    fun everyDetectedPeerIsOnTheRadarSortedWithMeasuredOrUnmeasuredSignal() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, registry)

        assertEquals(emptyList(), coordinator.radarPeers.value)
        engine.emitDetection(enin = 1, rpid = "r1", detectedDisplayId = "d0000002", rssi = -60, timestampMs = 1_000)
        assertEquals(emptyList(), coordinator.radarPeers.value, "no joined session, nothing on the radar")

        joinPromotedVectorEvent(coordinator, engine, registry)
        engine.emitDetection(enin = 1, rpid = "r1", detectedDisplayId = "D0000002", rssi = -60, timestampMs = 1_000)
        engine.emitDetection(enin = 1, rpid = "r2", detectedDisplayId = "d0000001", rssi = 0, timestampMs = 1_010)
        engine.emitDetection(enin = 1, rpid = "r3", detectedDisplayId = null, rssi = -40, timestampMs = 1_020)

        assertEquals(
            listOf(SensingRadarPeerSignal("d0000001", null), SensingRadarPeerSignal("d0000002", -60.0)),
            coordinator.radarPeers.value,
            "0 dBm is Barnard's no-measurement sentinel; an id-less observation is not a node",
        )
    }

    @Test
    fun rssiUpdatesAreSmoothedAndRepublishedAtMostEveryHalfSecond() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, registry)
        joinPromotedVectorEvent(coordinator, engine, registry)
        engine.emitDetection(enin = 1, rpid = "r1", detectedDisplayId = "d0000001", rssi = -60, timestampMs = 10_000)
        assertEquals(listOf(SensingRadarPeerSignal("d0000001", -60.0)), coordinator.radarPeers.value)

        engine.emitRssiUpdate(rssi = -40, detectedDisplayId = "d0000001", timestampMs = 10_499)
        assertEquals(-60.0, coordinator.radarPeers.value.single().dbm, "inside the 0.5 s interval: folded, not republished")

        engine.emitRssiUpdate(rssi = -40, detectedDisplayId = "d0000001", timestampMs = 10_500)
        // EMA alpha 0.25: -60 -> -55 -> -51.25.
        assertEquals(-51.25, coordinator.radarPeers.value.single().dbm)

        engine.emitRssiUpdate(rssi = 127, detectedDisplayId = "d0000001", timestampMs = 20_000)
        assertEquals(-51.25, coordinator.radarPeers.value.single().dbm, "127 is not a measurement")
    }

    @Test
    fun anRssiUpdateForAPeerNotYetDetectedDoesNotAddANode() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, registry)
        joinPromotedVectorEvent(coordinator, engine, registry)
        engine.emitRssiUpdate(rssi = -50, detectedDisplayId = "d0000009", timestampMs = 1_000)
        assertEquals(emptyList(), coordinator.radarPeers.value, "the radar draws detected peers only")
        engine.emitDetection(enin = 1, rpid = "r9", detectedDisplayId = "d0000009", rssi = 0, timestampMs = 1_100)
        assertEquals(listOf(SensingRadarPeerSignal("d0000009", -50.0)), coordinator.radarPeers.value)
    }

    @Test
    fun theRadarFreezesOnSignalLostAndClearsWhenTheSessionEnds() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, registry)
        joinPromotedVectorEvent(coordinator, engine, registry)
        recordSession(engine)
        engine.emitRssiUpdate(rssi = -70, detectedDisplayId = "d0000001", timestampMs = 5_000)
        val beforeLoss = coordinator.radarPeers.value
        // The detections measured -50 at t=0; EMA alpha 0.25 toward -70.
        assertEquals(-55.0, beforeLoss.first().dbm)

        coordinator.simulateSignalLost()
        engine.emitRssiUpdate(rssi = -30, detectedDisplayId = "d0000001", timestampMs = 9_000)
        assertEquals(beforeLoss, coordinator.radarPeers.value, "a frozen count gets a frozen radar")

        coordinator.leaveEvent()
        assertEquals(emptyList(), coordinator.radarPeers.value)
        joinPromotedVectorEvent(coordinator, engine, registry)
        engine.emitDetection(enin = 1, rpid = "r1", detectedDisplayId = "d0000001", rssi = 0, timestampMs = 9_100)
        assertEquals(listOf(SensingRadarPeerSignal("d0000001", null)), coordinator.radarPeers.value, "no radius survives into the next session")
    }

    // MARK: - Radar peer liveness (display only, iOS #855/#901)

    @Test
    fun aDetectionRecordsWhenItsPeerWasLastHeardAtTheBarnardTimestamp() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, registry)
        engine.emitDetection(enin = 1, rpid = "r1", detectedDisplayId = "d0000001", timestampMs = 1_000)
        assertNull(coordinator.radarPeerLastHeardAtMillis("d0000001"), "no joined session, nothing heard")

        joinPromotedVectorEvent(coordinator, engine, registry)
        engine.emitDetection(enin = 1, rpid = "r1", detectedDisplayId = "D0000001", rssi = 0, timestampMs = 10_000)
        engine.emitDetection(enin = 1, rpid = "r2", detectedDisplayId = "d0000002", timestampMs = 10_500)
        engine.emitDetection(enin = 1, rpid = "r3", detectedDisplayId = null, timestampMs = 11_000)

        assertEquals(10_000L, coordinator.radarPeerLastHeardAtMillis("d0000001"), "keyed by the normalized id")
        assertEquals(10_500L, coordinator.radarPeerLastHeardAtMillis("d0000002"))
        assertNull(coordinator.radarPeerLastHeardAtMillis("D0000001"))
    }

    @Test
    fun anOlderObservationArrivingLateNeverMovesLastHeardBack() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, registry)
        joinPromotedVectorEvent(coordinator, engine, registry)
        engine.emitDetection(enin = 1, rpid = "r1", detectedDisplayId = "d0000001", timestampMs = 20_000)
        engine.emitDetection(enin = 1, rpid = "r1", detectedDisplayId = "d0000001", timestampMs = 15_000)
        assertEquals(20_000L, coordinator.radarPeerLastHeardAtMillis("d0000001"))
        engine.emitRssiUpdate(rssi = -40, detectedDisplayId = "d0000001", timestampMs = 18_000)
        assertEquals(20_000L, coordinator.radarPeerLastHeardAtMillis("d0000001"))
    }

    @Test
    fun anRssiUpdateRefreshesADetectedPeerWithoutRepublishingTheRadar() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, registry)
        joinPromotedVectorEvent(coordinator, engine, registry)
        engine.emitDetection(enin = 1, rpid = "r1", detectedDisplayId = "d0000001", rssi = -60, timestampMs = 10_000)
        val published = coordinator.radarPeers.value

        engine.emitRssiUpdate(rssi = -40, detectedDisplayId = "D0000001", timestampMs = 10_400)
        assertEquals(10_400L, coordinator.radarPeerLastHeardAtMillis("d0000001"))
        assertSame(published, coordinator.radarPeers.value, "a folded sample moves lastHeard but publishes nothing")

        // As iOS: refreshed before the usability check, so an unusable sample still counts as heard.
        engine.emitRssiUpdate(rssi = 0, detectedDisplayId = "d0000001", timestampMs = 40_000)
        assertEquals(40_000L, coordinator.radarPeerLastHeardAtMillis("d0000001"))
        engine.emitRssiUpdate(rssi = 127, detectedDisplayId = "d0000001", timestampMs = 41_000)
        assertEquals(41_000L, coordinator.radarPeerLastHeardAtMillis("d0000001"))
    }

    @Test
    fun anRssiUpdateForAPeerNeverDetectedRecordsNothing() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, registry)
        joinPromotedVectorEvent(coordinator, engine, registry)
        engine.emitRssiUpdate(rssi = -50, detectedDisplayId = "d0000009", timestampMs = 1_000)
        engine.emitRssiUpdate(rssi = -50, detectedDisplayId = null, timestampMs = 1_000)
        assertNull(coordinator.radarPeerLastHeardAtMillis("d0000009"))
        assertEquals(emptyList(), coordinator.radarPeers.value)
    }

    @Test
    fun anRssiUpdateOutsideALiveSessionDoesNotRefreshLastHeard() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, registry)
        joinPromotedVectorEvent(coordinator, engine, registry)
        recordSession(engine)
        engine.emitRssiUpdate(rssi = -70, detectedDisplayId = "d0000001", timestampMs = 5_000)
        assertEquals(5_000L, coordinator.radarPeerLastHeardAtMillis("d0000001"))

        coordinator.simulateSignalLost()
        engine.emitRssiUpdate(rssi = -30, detectedDisplayId = "d0000001", timestampMs = 9_000)
        assertEquals(5_000L, coordinator.radarPeerLastHeardAtMillis("d0000001"), "SignalLost is frozen")

        coordinator.leaveEvent()
        engine.emitRssiUpdate(rssi = -30, detectedDisplayId = "d0000001", timestampMs = 9_500)
        assertNull(coordinator.radarPeerLastHeardAtMillis("d0000001"), "Idle: no session, nothing heard")
    }

    @Test
    fun aNewSessionStartsWithNoLastHeard() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, registry)
        joinPromotedVectorEvent(coordinator, engine, registry)
        engine.emitDetection(enin = 1, rpid = "r1", detectedDisplayId = "d0000001", timestampMs = 9_000)
        assertEquals(9_000L, coordinator.radarPeerLastHeardAtMillis("d0000001"))

        coordinator.leaveEvent()
        assertNull(coordinator.radarPeerLastHeardAtMillis("d0000001"))
        joinPromotedVectorEvent(coordinator, engine, registry)
        assertNull(coordinator.radarPeerLastHeardAtMillis("d0000001"), "nothing survives into the next session")
        engine.emitDetection(enin = 1, rpid = "r1", detectedDisplayId = "d0000001", timestampMs = 9_100)
        assertEquals(9_100L, coordinator.radarPeerLastHeardAtMillis("d0000001"))
    }

    private fun TestScope.coordinator(
        engine: FakeEventJoinEngine,
        registry: FakeNearbyEventRegistry,
        store: SigilPresenceStore? = null,
        snapshots: SessionAggregateSnapshotStore? = null,
        tokens: SigilPresenceTokenSource = SequentialTokens(),
        diagnostics: (String) -> Unit = {},
    ) = EventJoinCoordinator(
        engine = engine,
        nearbyRegistry = registry,
        nowEpochMillis = { NearbyEventPromotionFixture.VECTOR_NOW_EPOCH_MILLIS + testScheduler.currentTime },
        coroutineScope = backgroundScope,
        sensingCryptography = FakeSensingCryptography(),
        selfProofRecordStore = SelfProofRecordStore(newTempRecordFile("self-proofs")),
        bindingRecordStore = BindingRecordStore(newTempRecordFile("binding-records")),
        sessionAggregateSnapshotStore = snapshots,
        sigilPresenceStore = store,
        sigilPresenceTokenSource = tokens,
        joinDiagnostics = diagnostics,
    )

    private fun TestScope.ledgerCoordinator(
        owner: SessionCheckpointRuntimeOwner,
        engine: FakeEventJoinEngine,
        registry: FakeNearbyEventRegistry,
        store: SigilPresenceStore,
        tokens: SigilPresenceTokenSource = SequentialTokens(),
        diagnostics: (String) -> Unit = {},
    ) = EventJoinCoordinator(
        engine = engine,
        nowEpochMillis = { NearbyEventPromotionFixture.VECTOR_NOW_EPOCH_MILLIS + testScheduler.currentTime },
        coroutineScope = backgroundScope,
        nearbyRegistry = registry,
        sensingCryptography = FakeSensingCryptography(),
        selfProofRecordStore = SelfProofRecordStore(SelfProofRecordStore.defaultFile(directory)),
        bindingRecordStore = BindingRecordStore(BindingRecordStore.defaultFile(directory)),
        ledgerFilesDir = directory,
        checkpointDispatcher = StandardTestDispatcher(testScheduler),
        checkpointRuntimeOwner = owner,
        sigilPresenceStore = store,
        sigilPresenceTokenSource = tokens,
        joinDiagnostics = diagnostics,
    )
}
