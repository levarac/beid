package org.levarac.beid.sensing

import java.util.UUID
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.levarac.beid.persistence.BindingRecordStore
import org.levarac.beid.persistence.SelfProofRecord
import org.levarac.beid.persistence.SelfProofRecordStore
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue
import org.levarac.barnard.WalletBindingVerification
import org.levarac.barnard.WalletSignatureClassification

/**
 * `EventJoinCoordinator`'s owner-key wallet-binding coordinator API —
 * mirrors iOS's `SensingCoordinator` `beginBinding`/
 * `markBindingAwaitingApproval`/`completeBinding`/`failBinding`/
 * `declineBinding` (`ios/Beid/Sensing/SensingCoordinator.swift`).
 *
 * The production [WalletBindingFlow] calls this same API; most tests here
 * keep exercising the SDK-agnostic coordinator boundary directly, while the
 * flow tests below cover the connector-to-coordinator sequencing.
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
        val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, FakeSensingCryptography(), nearbyRegistry = registry)
        joinPromotedVectorEvent(coordinator, engine, registry)
        confirmRecording(engine)

        val messageHex = coordinator.beginBinding(walletAddress, chainId = 1)

        assertNotNull(messageHex)
        assertTrue(messageHex.startsWith("0x"))
        assertEquals(EventBindingState.Connecting, coordinator.bindingState)
    }

    @Test
    fun beginBindingReusesThePendingMessageAcrossCalls() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, FakeSensingCryptography(), nearbyRegistry = registry)
        joinPromotedVectorEvent(coordinator, engine, registry)
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
        val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, FakeSensingCryptography(), nearbyRegistry = registry)
        joinPromotedVectorEvent(coordinator, engine, registry)
        confirmRecording(engine)
        coordinator.beginBinding(walletAddress, chainId = 1)

        coordinator.markBindingAwaitingApproval()

        assertEquals(EventBindingState.AwaitingApproval, coordinator.bindingState)
    }

    @Test
    fun completeBindingReturnsNotVerifiedWithoutAnInFlightAttempt() = runTest {
        val coordinator = coordinator(FakeEventJoinEngine(), FakeSensingCryptography())

        assertIs<BindingCompletionResult.NotVerified>(coordinator.completeBinding(walletAddress, walletSignatureHex = "0x" + "0a".repeat(65)))
    }

    @Test
    fun mismatchedBindingAddressCannotReachOwnerSigningOrPersistence() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        var acknowledgementCalls = 0
        val crypto = object : FakeSensingCryptography() {
            override fun signWalletAcknowledgement(walletAddress: ByteArray, walletSignature: ByteArray): SensingRecoverableSignature? {
                acknowledgementCalls += 1
                return super.signWalletAcknowledgement(walletAddress, walletSignature)
            }
        }
        val file = newTempRecordFile("binding-address-mismatch")
        val store = BindingRecordStore(file)
        val coordinator = coordinator(engine, crypto, bindingRecordStore = store, nearbyRegistry = registry)
        var signatureUpdates = 0
        coordinator.onProofSignatureStateChanged = { _, _, _ -> signatureUpdates += 1 }
        joinPromotedVectorEvent(coordinator, engine, registry)
        confirmRecording(engine)
        val originalMessage = assertNotNull(coordinator.beginBinding(walletAddress, chainId = 1))
        val differentAddress = "0x" + "ab".repeat(20)
        // The pending request is deliberately reused even if a second caller
        // supplies another address. This makes the completion mismatch real.
        assertEquals(originalMessage, coordinator.beginBinding(differentAddress, chainId = 1))
        val stateBefore = coordinator.bindingState
        val diskBefore = if (file.exists()) file.readBytes().toList() else null

        for (address in listOf(differentAddress, "0xzz", "0x" + "ab".repeat(19))) {
            assertIs<BindingCompletionResult.NotVerified>(coordinator.completeBinding(address, "0x" + "0a".repeat(65)))
            assertEquals(0, acknowledgementCalls)
            assertTrue(store.records.isEmpty())
            assertEquals(stateBefore, coordinator.bindingState)
            assertEquals(diskBefore, if (file.exists()) file.readBytes().toList() else null)
            assertEquals(0, signatureUpdates)
        }
    }

    @Test
    fun bindingAddressComparisonUsesBytesAndRetainsTheOriginalPendingMessage() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val store = BindingRecordStore(newTempRecordFile("binding-address-case"))
        val coordinator = coordinator(engine, FakeSensingCryptography(), bindingRecordStore = store, nearbyRegistry = registry)
        joinPromotedVectorEvent(coordinator, engine, registry)
        confirmRecording(engine)
        val original = assertNotNull(coordinator.beginBinding(walletAddress, chainId = 1))
        assertIs<BindingCompletionResult.NotVerified>(coordinator.completeBinding("0x" + "ab".repeat(20), "0x" + "0a".repeat(65)))
        assertEquals(original, coordinator.beginBinding(walletAddress, chainId = 1))
        val sameAddress = "0x" + walletAddress.removePrefix("0x").uppercase()
        val record = assertIs<BindingCompletionResult.Bound>(coordinator.completeBinding(sameAddress, "0x" + "0a".repeat(65))).record
        assertEquals(listOf(record), store.records)
    }

    @Test
    fun completeBindingProducesAndPersistsABindingRecordAndMovesToBound() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val store = BindingRecordStore(newTempRecordFile("binding-records"))
        val cryptography = FakeSensingCryptography()
        val coordinator = coordinator(engine, cryptography, bindingRecordStore = store, nearbyRegistry = registry)
        joinPromotedVectorEvent(coordinator, engine, registry)
        confirmRecording(engine)
        coordinator.beginBinding(walletAddress, chainId = 1)

        val record = assertIs<BindingCompletionResult.Bound>(coordinator.completeBinding(walletAddress, walletSignatureHex = "0x" + "0a".repeat(65))).record

        assertEquals(1, cryptography.calls.count { it is FakeSensingCryptography.Call.SignWalletAcknowledgement })

        assertNotNull(record)
        assertEquals(NearbyEventPromotionFixture.EVENT_ID_HEX, record.eventCode)
        assertEquals(walletAddress, record.walletAddress)
        assertEquals(listOf(record), store.records)
        assertEquals(EventBindingState.Bound(record), coordinator.bindingState)
    }

    @Test
    fun completeBindingFiresOnProofSignatureStateChangedWithNoPriorSelfProof() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, FakeSensingCryptography(), nearbyRegistry = registry)
        val calls = mutableListOf<Triple<UUID, Boolean, Boolean>>()
        coordinator.onProofSignatureStateChanged = { proofId, hasSelfProof, hasBinding -> calls += Triple(proofId, hasSelfProof, hasBinding) }
        joinPromotedVectorEvent(coordinator, engine, registry)
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
        val registry = FakeNearbyEventRegistry()
        val selfProofStore = SelfProofRecordStore(newTempRecordFile("self-proofs"))
        val coordinator = coordinator(engine, FakeSensingCryptography(), selfProofRecordStore = selfProofStore, nearbyRegistry = registry)
        val proofIds = mutableListOf<UUID>()
        coordinator.onProofCollected = { proofId, _, _ -> proofIds += proofId }
        joinPromotedVectorEvent(coordinator, engine, registry)
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
        val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, FakeSensingCryptography(), nearbyRegistry = registry)
        joinPromotedVectorEvent(coordinator, engine, registry)
        confirmRecording(engine)
        coordinator.beginBinding(walletAddress, chainId = 1)

        coordinator.failBinding(WalletBindingFailure.Declined)

        assertEquals(EventBindingState.Failed(WalletBindingFailure.Declined), coordinator.bindingState)
        assertIs<BindingCompletionResult.NotVerified>(coordinator.completeBinding(walletAddress, walletSignatureHex = "0x" + "0a".repeat(65)), "the pending message must be gone after a failure")
    }

    @Test
    fun declineBindingReturnsToPendingConnectWhileStillRecording() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, FakeSensingCryptography(), nearbyRegistry = registry)
        joinPromotedVectorEvent(coordinator, engine, registry)
        confirmRecording(engine)
        coordinator.beginBinding(walletAddress, chainId = 1)

        coordinator.declineBinding()

        assertTrue(coordinator.bindingState is EventBindingState.PendingConnect, "wallet is optional — recording keeps running untouched")
    }

    @Test
    fun leaveEventResetsBindingStateEvenMidAttempt() = runTest {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, FakeSensingCryptography(), nearbyRegistry = registry)
        joinPromotedVectorEvent(coordinator, engine, registry)
        confirmRecording(engine)
        coordinator.beginBinding(walletAddress, chainId = 1)

        coordinator.leaveEvent()

        assertEquals(EventBindingState.None, coordinator.bindingState)
    }

    @Test
    fun walletBindingFlowConnectsSignsAndPersistsExactlyOnce() = runTest {
        val engine = FakeEventJoinEngine(); val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, FakeSensingCryptography(), nearbyRegistry = registry)
        joinPromotedVectorEvent(coordinator, engine, registry); confirmRecording(engine)
        val wallet = FakeWalletConnector(WalletConnectOutcome.Connected(live(walletAddress)), WalletConnectOutcome.Signed("0x" + "0a".repeat(65)))
        WalletBindingFlow(coordinator, wallet).start()
        assertTrue(coordinator.bindingState is EventBindingState.Bound)
        assertEquals(1, wallet.signCalls)
    }

    @Test
    fun walletCancellationShowsRetryableFailureWithoutPersistence() = runTest {
        val engine = FakeEventJoinEngine(); val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, FakeSensingCryptography(), nearbyRegistry = registry)
        joinPromotedVectorEvent(coordinator, engine, registry); confirmRecording(engine)
        val wallet = FakeWalletConnector(WalletConnectOutcome.Cancelled, WalletConnectOutcome.Cancelled)
        WalletBindingFlow(coordinator, wallet).start()
        assertEquals(EventBindingState.Failed(WalletBindingFailure.Declined), coordinator.bindingState)
        assertEquals(0, wallet.signCalls)

        coordinator.declineBinding()
        assertTrue(coordinator.bindingState is EventBindingState.PendingConnect)
    }

    @Test
    fun walletMalformedSignatureFailsWithoutBinding() = runTest {
        val engine = FakeEventJoinEngine(); val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, FakeSensingCryptography(), nearbyRegistry = registry)
        joinPromotedVectorEvent(coordinator, engine, registry); confirmRecording(engine)
        val wallet = FakeWalletConnector(WalletConnectOutcome.Connected(live(walletAddress)), WalletConnectOutcome.Signed("0x00"))
        WalletBindingFlow(coordinator, wallet).start()
        assertTrue(coordinator.bindingState is EventBindingState.Failed)
    }

    @Test
    fun completeBindingDoesNotAskOwnerToSign64ByteSignature() = runTest {
        assertInvalidSignatureDoesNotReachOwnerSigning(byteCount = 64)
    }

    @Test
    fun completeBindingDoesNotAskOwnerToSign66ByteSignature() = runTest {
        assertInvalidSignatureDoesNotReachOwnerSigning(byteCount = 66)
    }

    private suspend fun TestScope.assertInvalidSignatureDoesNotReachOwnerSigning(byteCount: Int) {
        val engine = FakeEventJoinEngine()
        val registry = FakeNearbyEventRegistry()
        // Return null after recording the call so a removed classification gate
        // still yields NotVerified. The call count, not that result, must catch it.
        val cryptography = FakeSensingCryptography(walletAcknowledgementSignatureResult = null)
        val coordinator = coordinator(engine, cryptography, nearbyRegistry = registry)
        joinPromotedVectorEvent(coordinator, engine, registry)
        confirmRecording(engine)
        assertNotNull(coordinator.beginBinding(walletAddress, chainId = 1))

        val result = coordinator.completeBinding(walletAddress, "0x" + "ab".repeat(byteCount))

        assertEquals(0, cryptography.calls.count { it is FakeSensingCryptography.Call.SignWalletAcknowledgement })
        assertIs<BindingCompletionResult.NotVerified>(result)
    }

    @Test
    fun erc6492SignatureIsUnsupportedBeforeOwnerAcknowledgementSigning() = runTest {
        val engine = FakeEventJoinEngine(); val registry = FakeNearbyEventRegistry()
        val cryptography = FakeSensingCryptography(
            walletAcknowledgementSignatureResult = null,
            walletSignatureClassification = WalletSignatureClassification.SMART_WALLET_UNSUPPORTED,
        )
        val coordinator = coordinator(engine, cryptography, nearbyRegistry = registry)
        joinPromotedVectorEvent(coordinator, engine, registry); confirmRecording(engine)
        assertNotNull(coordinator.beginBinding(walletAddress, chainId = 1))

        val result = coordinator.completeBinding(
            walletAddress,
            "0x" + "cd".repeat(32) + "6492".repeat(16),
        )

        assertEquals(0, cryptography.calls.count { it is FakeSensingCryptography.Call.SignWalletAcknowledgement })
        assertIs<BindingCompletionResult.SmartWalletUnsupported>(result)
    }

    @Test
    fun walletSignatureCannotBePersistedUnderADifferentAddress() = runTest {
        val engine = FakeEventJoinEngine(); val registry = FakeNearbyEventRegistry()
        val store = BindingRecordStore(newTempRecordFile("binding-records"))
        val coordinator = coordinator(engine, FakeSensingCryptography(), bindingRecordStore = store, nearbyRegistry = registry)
        joinPromotedVectorEvent(coordinator, engine, registry); confirmRecording(engine)
        coordinator.beginBinding(walletAddress, chainId = 1)
        val otherAddress = "0x" + "22".repeat(20)
        assertIs<BindingCompletionResult.NotVerified>(coordinator.completeBinding(otherAddress, "0x" + "0a".repeat(65)))
        assertTrue(store.records.isEmpty())
    }

    @Test
    fun leavingEventInvalidatesLateWalletCallback() = runTest {
        val engine = FakeEventJoinEngine(); val registry = FakeNearbyEventRegistry()
        val store = BindingRecordStore(newTempRecordFile("binding-records"))
        val coordinator = coordinator(engine, FakeSensingCryptography(), bindingRecordStore = store, nearbyRegistry = registry)
        joinPromotedVectorEvent(coordinator, engine, registry); confirmRecording(engine)
        val wallet = DeferredWalletConnector()
        WalletBindingFlow(coordinator, wallet).start()
        coordinator.leaveEvent()
        wallet.connectCallback?.invoke(WalletConnectOutcome.Connected(live(walletAddress)))
        assertTrue(store.records.isEmpty())
    }

    @Test
    fun oldAttemptCallbacksCannotCompleteAReusedFlow() = runTest {
        val engine = FakeEventJoinEngine(); val registry = FakeNearbyEventRegistry()
        val coordinator = coordinator(engine, FakeSensingCryptography(), nearbyRegistry = registry)
        joinPromotedVectorEvent(coordinator, engine, registry); confirmRecording(engine)
        val wallet = MultiDeferredWalletConnector(); val flow = WalletBindingFlow(coordinator, wallet)
        flow.start()
        wallet.connectCallbacks[0](WalletConnectOutcome.Connected(live(walletAddress)))
        flow.cancel(); flow.start()
        wallet.connectCallbacks[1](WalletConnectOutcome.Connected(live(walletAddress)))
        wallet.signCallbacks[0](WalletConnectOutcome.Signed("0x" + "0a".repeat(65)))
        assertTrue(coordinator.bindingState is EventBindingState.AwaitingApproval)
        wallet.signCallbacks[1](WalletConnectOutcome.Signed("0x" + "0a".repeat(65)))
        assertTrue(coordinator.bindingState is EventBindingState.Bound)
    }

    @Test
    fun restoredHintUsesOneConnectAndSignRoundTripAndPersistsOnlyTheLiveResult() = runTest {
        val engine = FakeEventJoinEngine(); val registry = FakeNearbyEventRegistry()
        val store = BindingRecordStore(newTempRecordFile("restored-binding"))
        val coordinator = coordinator(
            engine,
            FakeSensingCryptography(),
            bindingRecordStore = store,
            nearbyRegistry = registry,
        )
        joinPromotedVectorEvent(coordinator, engine, registry); confirmRecording(engine)
        val hint = CachedWalletHint(walletAddress.uppercase(), 1L)
        val wallet = RestoredWalletConnector(hint, live(walletAddress))

        WalletBindingFlow(coordinator, wallet).start()

        assertEquals(1, wallet.connectAndSignCalls)
        assertEquals(0, wallet.connectCalls)
        assertEquals(0, wallet.personalSignCalls)
        assertEquals(walletAddress, store.records.single().walletAddress)
    }

    @Test
    fun restoredRoundTripKeepsTheChainThatWasEmbeddedInTheSignedPendingMessage() = runTest {
        val engine = FakeEventJoinEngine(); val registry = FakeNearbyEventRegistry()
        val store = BindingRecordStore(newTempRecordFile("restored-chain"))
        val coordinator = coordinator(
            engine,
            FakeSensingCryptography(),
            bindingRecordStore = store,
            nearbyRegistry = registry,
        )
        joinPromotedVectorEvent(coordinator, engine, registry); confirmRecording(engine)
        val wallet = RestoredWalletConnector(
            CachedWalletHint(walletAddress, 1L),
            live(walletAddress, chainId = 8453L),
        )

        WalletBindingFlow(coordinator, wallet).start()

        assertEquals(1L, store.records.single().chainId, "the signed pending message, not a later SDK field, owns the record chain")
    }

    @Test
    fun accountSwitchAfterRestoreCannotPersistUntilExplicitRetryBuildsForLiveAccount() = runTest {
        val engine = FakeEventJoinEngine(); val registry = FakeNearbyEventRegistry()
        val store = BindingRecordStore(newTempRecordFile("restored-switch"))
        val coordinator = coordinator(
            engine,
            FakeSensingCryptography(),
            bindingRecordStore = store,
            nearbyRegistry = registry,
        )
        joinPromotedVectorEvent(coordinator, engine, registry); confirmRecording(engine)
        val oldHint = CachedWalletHint("0x" + "11".repeat(20), 1L)
        val switchedLive = live(walletAddress, chainId = 8453L)
        val wallet = RestoredWalletConnector(oldHint, switchedLive)
        val flow = WalletBindingFlow(coordinator, wallet)

        flow.start()

        assertTrue(store.records.isEmpty(), "completeBinding must reject the live address against the restored pending message")
        assertTrue(coordinator.bindingState is EventBindingState.Failed)
        assertEquals(1, wallet.connectAndSignCalls)
        assertEquals(0, wallet.personalSignCalls)

        flow.start()

        val record = store.records.single()
        assertEquals(switchedLive.address, record.walletAddress)
        assertEquals(switchedLive.chainId, record.chainId)
        assertEquals(1, wallet.connectAndSignCalls, "retry must use the already-live SDK session")
        assertEquals(1, wallet.personalSignCalls)
    }

    @Test
    fun leavingEventInvalidatesLateRestoredConnectAndSignCallback() = runTest {
        val engine = FakeEventJoinEngine(); val registry = FakeNearbyEventRegistry()
        val store = BindingRecordStore(newTempRecordFile("restored-late-callback"))
        val coordinator = coordinator(
            engine,
            FakeSensingCryptography(),
            bindingRecordStore = store,
            nearbyRegistry = registry,
        )
        joinPromotedVectorEvent(coordinator, engine, registry); confirmRecording(engine)
        val wallet = DeferredRestoredWalletConnector(CachedWalletHint(walletAddress, 1L))

        WalletBindingFlow(coordinator, wallet).start()
        coordinator.leaveEvent()
        wallet.connectAndSignCallback?.invoke(
            WalletConnectOutcome.ConnectedAndSigned(live(walletAddress), "0x" + "0a".repeat(65)),
        )

        assertTrue(store.records.isEmpty())
    }

    private class FakeWalletConnector(
        private val connection: WalletConnectOutcome,
        private val signing: WalletConnectOutcome,
    ) : WalletConnector {
        override val state: StateFlow<WalletConnectorState> = MutableStateFlow(WalletConnectorState.Idle)
        var signCalls = 0
        override fun connect(callback: (WalletConnectOutcome) -> Unit) = callback(connection)
        override fun connectAndSign(messageHex: String, callback: (WalletConnectOutcome) -> Unit) =
            callback(WalletConnectOutcome.Failed(WalletBindingFailure.NotConnected))
        override fun personalSign(address: LiveWalletAddress, messageHex: String, callback: (WalletConnectOutcome) -> Unit) {
            signCalls += 1; callback(signing)
        }
        override fun cancelPendingOperation() = Unit
        override fun disconnect() = Unit
    }

    private class DeferredWalletConnector : WalletConnector {
        override val state: StateFlow<WalletConnectorState> = MutableStateFlow(WalletConnectorState.Idle)
        var connectCallback: ((WalletConnectOutcome) -> Unit)? = null
        override fun connect(callback: (WalletConnectOutcome) -> Unit) { connectCallback = callback }
        override fun connectAndSign(messageHex: String, callback: (WalletConnectOutcome) -> Unit) = Unit
        override fun personalSign(address: LiveWalletAddress, messageHex: String, callback: (WalletConnectOutcome) -> Unit) = Unit
        override fun cancelPendingOperation() = Unit
        override fun disconnect() = Unit
    }

    private class MultiDeferredWalletConnector : WalletConnector {
        override val state: StateFlow<WalletConnectorState> = MutableStateFlow(WalletConnectorState.Idle)
        val connectCallbacks = mutableListOf<(WalletConnectOutcome) -> Unit>()
        val signCallbacks = mutableListOf<(WalletConnectOutcome) -> Unit>()
        override fun connect(callback: (WalletConnectOutcome) -> Unit) { connectCallbacks += callback }
        override fun connectAndSign(messageHex: String, callback: (WalletConnectOutcome) -> Unit) = Unit
        override fun personalSign(address: LiveWalletAddress, messageHex: String, callback: (WalletConnectOutcome) -> Unit) { signCallbacks += callback }
        override fun cancelPendingOperation() = Unit
        override fun disconnect() = Unit
    }

    private class RestoredWalletConnector(
        hint: CachedWalletHint,
        private val liveResult: LiveWalletAddress,
    ) : WalletConnector {
        private val mutableState = MutableStateFlow<WalletConnectorState>(WalletConnectorState.Restored(hint))
        override val state: StateFlow<WalletConnectorState> = mutableState
        var connectCalls = 0
        var connectAndSignCalls = 0
        var personalSignCalls = 0

        override fun connect(callback: (WalletConnectOutcome) -> Unit) {
            connectCalls += 1
            callback(WalletConnectOutcome.Connected(liveResult))
        }

        override fun connectAndSign(messageHex: String, callback: (WalletConnectOutcome) -> Unit) {
            connectAndSignCalls += 1
            mutableState.value = WalletConnectorState.Connected(liveResult)
            callback(WalletConnectOutcome.ConnectedAndSigned(liveResult, "0x" + "0a".repeat(65)))
        }

        override fun personalSign(
            address: LiveWalletAddress,
            messageHex: String,
            callback: (WalletConnectOutcome) -> Unit,
        ) {
            personalSignCalls += 1
            callback(WalletConnectOutcome.Signed("0x" + "0a".repeat(65)))
        }

        override fun cancelPendingOperation() = Unit
        override fun disconnect() = Unit
    }

    private class DeferredRestoredWalletConnector(hint: CachedWalletHint) : WalletConnector {
        override val state: StateFlow<WalletConnectorState> = MutableStateFlow(WalletConnectorState.Restored(hint))
        var connectAndSignCallback: ((WalletConnectOutcome) -> Unit)? = null
        override fun connect(callback: (WalletConnectOutcome) -> Unit) = Unit
        override fun connectAndSign(messageHex: String, callback: (WalletConnectOutcome) -> Unit) {
            connectAndSignCallback = callback
        }
        override fun personalSign(
            address: LiveWalletAddress,
            messageHex: String,
            callback: (WalletConnectOutcome) -> Unit,
        ) = Unit
        override fun cancelPendingOperation() = Unit
        override fun disconnect() = Unit
    }

    private fun live(address: String, chainId: Long = 1L): LiveWalletAddress =
        LiveWalletAddress.fromConnectorResult(address, chainId)

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
        nearbyRegistry: FakeNearbyEventRegistry = FakeNearbyEventRegistry(),
    ): EventJoinCoordinator = EventJoinCoordinator(
        engine = engine,
        nearbyRegistry = nearbyRegistry,
        nowEpochMillis = { NearbyEventPromotionFixture.VECTOR_NOW_EPOCH_MILLIS + testScheduler.currentTime },
        coroutineScope = backgroundScope,
        sensingCryptography = cryptography,
        selfProofRecordStore = selfProofRecordStore,
        bindingRecordStore = bindingRecordStore,
    )
}
