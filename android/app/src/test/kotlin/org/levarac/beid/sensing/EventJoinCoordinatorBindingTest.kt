package org.levarac.beid.sensing

import java.util.UUID
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.levarac.beid.persistence.BindingRecordStore
import org.levarac.beid.persistence.SelfProofRecord
import org.levarac.beid.persistence.SelfProofRecordStore
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * `EventJoinCoordinator`'s owner-key wallet-binding coordinator API —
 * mirrors iOS's `SensingCoordinator` `beginBinding`/
 * `markBindingAwaitingApproval`/`completeBinding`/`failBinding`/
 * `declineBinding` (`ios/Beid/Sensing/SensingCoordinator.swift`).
 *
 * **No wallet-connect UI caller wires into this yet — that is #124's
 * scope, not this task's.** These tests exercise the coordinator API
 * directly with an already-obtained wallet address/signature, the same way
 * `beginBinding`/`completeBinding` are wallet-SDK-agnostic on iOS (the
 * actual `WalletConnector` negotiation lives in `EventBindingSheetView`,
 * not the coordinator).
 */
@OptIn(ExperimentalCoroutinesApi::class)
class EventJoinCoordinatorBindingTest {
    private val walletAddress = "0x14791697260e4c9a71f18484c9f997b308e59325"

    @Test
    fun beginBindingReturnsNullWhenNotRecording() = runTest {
        val coordinator = coordinator(FakeEventJoinEngine(), FakeSensingCryptography())

        assertNull(coordinator.beginBinding(walletAddress, chainId = 1))
    }

    @Test
    fun beginBindingReturnsHexPrefixedTextAndMovesToConnecting() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine, FakeSensingCryptography())
        coordinator.joinEvent("BIND-EVENT")
        runCurrent()
        confirmRecording(engine)

        val messageHex = coordinator.beginBinding(walletAddress, chainId = 1)

        assertNotNull(messageHex)
        assertTrue(messageHex.startsWith("0x"))
        assertEquals(EventBindingState.Connecting, coordinator.bindingState)
    }

    @Test
    fun beginBindingReusesThePendingMessageAcrossCalls() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine, FakeSensingCryptography())
        coordinator.joinEvent("BIND-EVENT")
        runCurrent()
        confirmRecording(engine)

        val first = coordinator.beginBinding(walletAddress, chainId = 1)
        val second = coordinator.beginBinding(walletAddress, chainId = 1)

        assertEquals(first, second, "recomputing with a fresh nonce/issuedAt would desync the wallet signature and the later wallet-ack")
    }

    @Test
    fun markBindingAwaitingApprovalNoOpsUnlessConnecting() = runTest {
        val coordinator = coordinator(FakeEventJoinEngine(), FakeSensingCryptography())

        coordinator.markBindingAwaitingApproval()

        assertEquals(EventBindingState.None, coordinator.bindingState)
    }

    @Test
    fun markBindingAwaitingApprovalMovesFromConnecting() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine, FakeSensingCryptography())
        coordinator.joinEvent("BIND-EVENT")
        runCurrent()
        confirmRecording(engine)
        coordinator.beginBinding(walletAddress, chainId = 1)

        coordinator.markBindingAwaitingApproval()

        assertEquals(EventBindingState.AwaitingApproval, coordinator.bindingState)
    }

    @Test
    fun completeBindingReturnsNullWithoutAnInFlightAttempt() = runTest {
        val coordinator = coordinator(FakeEventJoinEngine(), FakeSensingCryptography())

        assertNull(coordinator.completeBinding(walletAddress, walletSignatureHex = "0x" + "0a".repeat(65)))
    }

    @Test
    fun completeBindingProducesAndPersistsABindingRecordAndMovesToBound() = runTest {
        val engine = FakeEventJoinEngine()
        val store = BindingRecordStore(newTempRecordFile("binding-records"))
        val coordinator = coordinator(engine, FakeSensingCryptography(), bindingRecordStore = store)
        coordinator.joinEvent("BIND-EVENT")
        runCurrent()
        confirmRecording(engine)
        coordinator.beginBinding(walletAddress, chainId = 1)

        val record = coordinator.completeBinding(walletAddress, walletSignatureHex = "0x" + "0a".repeat(65))

        assertNotNull(record)
        assertEquals("BIND-EVENT", record.eventCode)
        assertEquals(walletAddress, record.walletAddress)
        assertEquals(listOf(record), store.records)
        assertEquals(EventBindingState.Bound(record), coordinator.bindingState)
    }

    @Test
    fun completeBindingFiresOnProofSignatureStateChangedWithNoPriorSelfProof() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine, FakeSensingCryptography())
        val calls = mutableListOf<Triple<UUID, Boolean, Boolean>>()
        coordinator.onProofSignatureStateChanged = { proofId, hasSelfProof, hasBinding -> calls += Triple(proofId, hasSelfProof, hasBinding) }
        coordinator.joinEvent("BIND-EVENT")
        runCurrent()
        confirmRecording(engine)
        coordinator.beginBinding(walletAddress, chainId = 1)

        coordinator.completeBinding(walletAddress, walletSignatureHex = "0x" + "0a".repeat(65))

        val (_, hasSelfProof, hasBinding) = calls.single()
        assertTrue(!hasSelfProof, "self-proof is only persisted at session end — none exists yet")
        assertTrue(hasBinding, "the binding this call just persisted")
    }

    @Test
    fun completeBindingFiresOnProofSignatureStateChangedWithSelfProofAlreadyPresent() = runTest {
        val engine = FakeEventJoinEngine()
        val selfProofStore = SelfProofRecordStore(newTempRecordFile("self-proofs"))
        val coordinator = coordinator(engine, FakeSensingCryptography(), selfProofRecordStore = selfProofStore)
        val proofIds = mutableListOf<UUID>()
        coordinator.onProofCollected = { proofId, _, _ -> proofIds += proofId }
        coordinator.joinEvent("BIND-EVENT")
        runCurrent()
        confirmRecording(engine)
        val proofId = proofIds.single()
        selfProofStore.add(
            SelfProofRecord(
                proofId = proofId,
                eventCode = "BIND-EVENT",
                eventIdHash = EventIdHash.compute("BIND-EVENT"),
                eventSigningPublicKey = sequentialBytes(0x02, 33),
                eninStart = 1,
                eninEnd = 3,
                ownerPublicKey = sequentialBytes(0x03, 33),
                signature = SensingRecoverableSignature(r = sequentialBytes(0x10, 32), s = sequentialBytes(0x20, 32), v = 0),
            ),
        )
        val calls = mutableListOf<Triple<UUID, Boolean, Boolean>>()
        coordinator.onProofSignatureStateChanged = { id, hasSelfProof, hasBinding -> calls += Triple(id, hasSelfProof, hasBinding) }
        coordinator.beginBinding(walletAddress, chainId = 1)

        coordinator.completeBinding(walletAddress, walletSignatureHex = "0x" + "0a".repeat(65))

        val (_, hasSelfProof, hasBinding) = calls.single()
        assertTrue(hasSelfProof, "a self-proof for this Proof was already persisted before completeBinding ran")
        assertTrue(hasBinding)
    }

    @Test
    fun failBindingClearsThePendingMessageAndRecordsTheReason() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine, FakeSensingCryptography())
        coordinator.joinEvent("BIND-EVENT")
        runCurrent()
        confirmRecording(engine)
        coordinator.beginBinding(walletAddress, chainId = 1)

        coordinator.failBinding("wallet declined")

        assertEquals(EventBindingState.Failed("wallet declined"), coordinator.bindingState)
        assertNull(coordinator.completeBinding(walletAddress, walletSignatureHex = "0x" + "0a".repeat(65)), "the pending message must be gone after a failure")
    }

    @Test
    fun declineBindingReturnsToPendingConnectWhileStillRecording() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine, FakeSensingCryptography())
        coordinator.joinEvent("BIND-EVENT")
        runCurrent()
        confirmRecording(engine)
        coordinator.beginBinding(walletAddress, chainId = 1)

        coordinator.declineBinding()

        assertTrue(coordinator.bindingState is EventBindingState.PendingConnect, "wallet is optional — recording keeps running untouched")
    }

    @Test
    fun leaveEventResetsBindingStateEvenMidAttempt() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine, FakeSensingCryptography())
        coordinator.joinEvent("BIND-EVENT")
        runCurrent()
        confirmRecording(engine)
        coordinator.beginBinding(walletAddress, chainId = 1)

        coordinator.leaveEvent()

        assertEquals(EventBindingState.None, coordinator.bindingState)
    }

    private fun confirmRecording(engine: FakeEventJoinEngine) {
        engine.emitDetection(enin = 1, rpid = "aa", detectedDisplayId = "device-1")
        engine.emitDetection(enin = 2, rpid = "bb", detectedDisplayId = "device-2")
        engine.emitDetection(enin = 3, rpid = "cc", detectedDisplayId = "device-3")
    }

    private fun TestScope.coordinator(
        engine: FakeEventJoinEngine,
        cryptography: FakeSensingCryptography,
        selfProofRecordStore: SelfProofRecordStore = SelfProofRecordStore(newTempRecordFile("self-proofs")),
        bindingRecordStore: BindingRecordStore = BindingRecordStore(newTempRecordFile("binding-records")),
    ): EventJoinCoordinator = EventJoinCoordinator(
        engine = engine,
        joinRegistry = FakeEventJoinRegistry(),
        nowEpochMillis = { testScheduler.currentTime },
        coroutineScope = backgroundScope,
        sensingCryptography = cryptography,
        selfProofRecordStore = selfProofRecordStore,
        bindingRecordStore = bindingRecordStore,
    )
}
