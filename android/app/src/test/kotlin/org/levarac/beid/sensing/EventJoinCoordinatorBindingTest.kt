package org.levarac.beid.sensing

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.levarac.beid.persistence.BindingRecordStore
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
    fun failBindingClearsThePendingMessageAndRecordsTheReason() = runTest {
        val engine = FakeEventJoinEngine()
        val coordinator = coordinator(engine, FakeSensingCryptography())
        coordinator.joinEvent("BIND-EVENT")
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
        nowEpochMillis = { testScheduler.currentTime },
        coroutineScope = backgroundScope,
        sensingCryptography = cryptography,
        selfProofRecordStore = selfProofRecordStore,
        bindingRecordStore = bindingRecordStore,
    )
}
