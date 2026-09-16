package org.levarac.beid.sensing

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNull

class MetaMaskWalletConnectorTest {
    private val oldHint = CachedWalletHint("0x" + "11".repeat(20), 1L)
    private val liveAddress = "0x" + "22".repeat(20)

    @Test
    fun freshConnectorExposesPersistedHintAsRestoredDisplayOnlyState() {
        val connector = MetaMaskWalletConnector(FakeTransport(), InMemoryHintStore(oldHint))

        assertEquals(WalletConnectorState.Restored(oldHint), connector.state.value)
    }

    @Test
    fun connectAndSignUsesPinnedSingleRequestAndReadsLiveAccountOnlyAfterSuccess() {
        val transport = FakeTransport(selectedAddress = oldHint.address, chainId = "0x1")
        val store = InMemoryHintStore(oldHint)
        val connector = MetaMaskWalletConnector(transport, store)
        var outcome: WalletConnectOutcome? = null

        connector.connectAndSign("0x1234") { outcome = it }
        assertEquals(listOf("connectSign:0x1234"), transport.calls)
        assertNull(outcome)

        transport.selectedAddress = liveAddress
        transport.chainId = "eip155:8453"
        transport.complete(MetaMaskTransportResult.Value("0x" + "0a".repeat(65)))

        val result = assertIs<WalletConnectOutcome.ConnectedAndSigned>(outcome)
        assertEquals(liveAddress, result.live.address)
        assertEquals(8453L, result.live.chainId)
        assertEquals(CachedWalletHint(liveAddress, 8453L), store.hint)
        assertEquals(WalletConnectorState.Connected(result.live), connector.state.value)
    }

    @Test
    fun lightCancellationPreservesHintAndIgnoresLateSdkCallback() {
        val transport = FakeTransport(selectedAddress = liveAddress, chainId = "0x1")
        val store = InMemoryHintStore(oldHint)
        val connector = MetaMaskWalletConnector(transport, store)
        var callbackCount = 0
        connector.connectAndSign("0x1234") { callbackCount += 1 }

        connector.cancelPendingOperation()
        transport.complete(MetaMaskTransportResult.Value("0x" + "0a".repeat(65)))

        assertEquals(0, callbackCount)
        assertEquals(oldHint, store.hint)
        assertEquals(WalletConnectorState.Restored(oldHint), connector.state.value)
        assertEquals(0, transport.disconnectCalls)
    }

    @Test
    fun walletSideCancellationRestoresHintWithoutDisconnectingSession() {
        val transport = FakeTransport()
        val store = InMemoryHintStore(oldHint)
        val connector = MetaMaskWalletConnector(transport, store)
        var outcome: WalletConnectOutcome? = null
        connector.connectAndSign("0x1234") { outcome = it }

        transport.complete(MetaMaskTransportResult.Cancelled)

        assertEquals(WalletConnectOutcome.Cancelled, outcome)
        assertEquals(oldHint, store.hint)
        assertEquals(WalletConnectorState.Restored(oldHint), connector.state.value)
        assertEquals(0, transport.disconnectCalls)
    }

    @Test
    fun explicitDisconnectIsTheOnlyPathThatClearsHintAndSdkSession() {
        val transport = FakeTransport()
        val store = InMemoryHintStore(oldHint)
        val connector = MetaMaskWalletConnector(transport, store)

        connector.disconnect()

        assertNull(store.hint)
        assertEquals(1, store.clearCalls)
        assertEquals(1, transport.disconnectCalls)
        assertEquals(WalletConnectorState.Idle, connector.state.value)
    }

    @Test
    fun signingFailureKeepsLiveSessionAndHintAvailableForLightRetry() {
        val transport = FakeTransport(selectedAddress = liveAddress, chainId = "0x1")
        val store = InMemoryHintStore()
        val connector = MetaMaskWalletConnector(transport, store)
        var connected: LiveWalletAddress? = null
        connector.connect { connected = assertIs<WalletConnectOutcome.Connected>(it).live }
        transport.complete(MetaMaskTransportResult.Success)

        connector.personalSign(requireNotNull(connected), "0x1234") { }
        transport.complete(MetaMaskTransportResult.Failed("temporary transport failure"))

        val failed = assertIs<WalletConnectorState.Failed>(connector.state.value)
        assertEquals(connected, failed.live)
        assertEquals(CachedWalletHint(liveAddress, 1L), store.hint)
        assertEquals(0, transport.disconnectCalls)

        connector.cancelPendingOperation()
        assertEquals(WalletConnectorState.Connected(connected!!), connector.state.value)
    }

    @Test
    fun personalSignRejectsAnAddressNotProducedByTheCurrentLiveSession() {
        val transport = FakeTransport(selectedAddress = liveAddress, chainId = "0x1")
        val connector = MetaMaskWalletConnector(transport, InMemoryHintStore())
        connector.connect { }
        transport.complete(MetaMaskTransportResult.Success)
        var outcome: WalletConnectOutcome? = null

        connector.personalSign(
            LiveWalletAddress.fromConnectorResult(oldHint.address, oldHint.chainId),
            "0x1234",
        ) { outcome = it }

        assertIs<WalletConnectOutcome.Failed>(outcome)
        assertEquals(listOf("connect"), transport.calls)
    }

    private class InMemoryHintStore(initial: CachedWalletHint? = null) : WalletHintStorage {
        var hint: CachedWalletHint? = initial
        var clearCalls = 0
        override fun load(): CachedWalletHint? = hint
        override fun save(hint: CachedWalletHint) { this.hint = hint }
        override fun clear() { clearCalls += 1; hint = null }
    }

    private class FakeTransport(
        override var selectedAddress: String = "",
        override var chainId: String = "",
    ) : MetaMaskTransport {
        val calls = mutableListOf<String>()
        var disconnectCalls = 0
        private var callback: ((MetaMaskTransportResult) -> Unit)? = null

        override fun connect(callback: (MetaMaskTransportResult) -> Unit) {
            calls += "connect"
            this.callback = callback
        }

        override fun connectSign(messageHex: String, callback: (MetaMaskTransportResult) -> Unit) {
            calls += "connectSign:$messageHex"
            this.callback = callback
        }

        override fun personalSign(
            messageHex: String,
            address: String,
            callback: (MetaMaskTransportResult) -> Unit,
        ) {
            calls += "personalSign:$address:$messageHex"
            this.callback = callback
        }

        override fun disconnect() { disconnectCalls += 1 }

        fun complete(result: MetaMaskTransportResult) {
            callback?.invoke(result)
        }
    }
}
