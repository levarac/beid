package org.levarac.beid.sensing

import android.content.Context
import io.metamask.androidsdk.CommunicationClientModule
import io.metamask.androidsdk.CommunicationClientModuleInterface
import io.metamask.androidsdk.DappMetadata
import io.metamask.androidsdk.Ethereum
import io.metamask.androidsdk.Result
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Address read from this process's live MetaMask SDK result. The only
 * production construction path is [fromConnectorResult], in this file.
 * Cached display text cannot be passed to binding completion as this type.
 */
class LiveWalletAddress private constructor(
    val address: String,
    val chainId: Long,
) {
    internal companion object {
        internal fun fromConnectorResult(address: String, chainId: Long) = LiveWalletAddress(address, chainId)
    }

    override fun equals(other: Any?): Boolean =
        other is LiveWalletAddress && address == other.address && chainId == other.chainId

    override fun hashCode(): Int = 31 * address.hashCode() + chainId.hashCode()

    override fun toString(): String = "LiveWalletAddress(address=$address, chainId=$chainId)"
}

sealed class WalletConnectorState {
    data object Idle : WalletConnectorState()
    data class Restored(val hint: CachedWalletHint) : WalletConnectorState()
    data class Connecting(val hint: CachedWalletHint?) : WalletConnectorState()
    data class AwaitingApproval(val hint: CachedWalletHint?) : WalletConnectorState()
    data class Connected(val live: LiveWalletAddress) : WalletConnectorState()
    data class Failed(
        val reason: String,
        val hint: CachedWalletHint?,
        val live: LiveWalletAddress? = null,
    ) : WalletConnectorState()
}

sealed class WalletConnectOutcome {
    data class Connected(val live: LiveWalletAddress) : WalletConnectOutcome()
    data class Signed(val signatureHex: String) : WalletConnectOutcome()
    data class ConnectedAndSigned(val live: LiveWalletAddress, val signatureHex: String) : WalletConnectOutcome()
    data object Cancelled : WalletConnectOutcome()
    data class Failed(val failure: WalletBindingFailure) : WalletConnectOutcome()
}

interface WalletConnector {
    val state: StateFlow<WalletConnectorState>
    fun connect(callback: (WalletConnectOutcome) -> Unit)
    fun connectAndSign(messageHex: String, callback: (WalletConnectOutcome) -> Unit)
    fun personalSign(address: LiveWalletAddress, messageHex: String, callback: (WalletConnectOutcome) -> Unit)
    fun cancelPendingOperation()
    fun disconnect()
}

internal sealed class MetaMaskTransportResult {
    data object Success : MetaMaskTransportResult()
    data class Value(val value: String) : MetaMaskTransportResult()
    data object Cancelled : MetaMaskTransportResult()
    data class Failed(val reason: String) : MetaMaskTransportResult()
}

internal interface MetaMaskTransport {
    val selectedAddress: String
    val chainId: String
    fun connect(callback: (MetaMaskTransportResult) -> Unit)
    fun connectSign(messageHex: String, callback: (MetaMaskTransportResult) -> Unit)
    fun personalSign(messageHex: String, address: String, callback: (MetaMaskTransportResult) -> Unit)
    fun disconnect()
}

/** The only class that translates the pinned MetaMask Android SDK's result model. */
internal class MetaMaskSdkTransport(
    context: Context,
    communicationClientModule: CommunicationClientModuleInterface = CommunicationClientModule(context.applicationContext),
) : MetaMaskTransport {
    // SDK 0.6.6 uses this flag to gate outbound analytics/tracking.
    private val ethereum = Ethereum(
        context = context.applicationContext,
        dappMetadata = DappMetadata("Beid", "https://beid.levarac.org"),
        communicationClientModule = communicationClientModule,
    ).enableDebug(false)
    private val callbackDispatcher = MainThreadWalletCallbackDispatcher()

    override val selectedAddress: String get() = ethereum.selectedAddress
    override val chainId: String get() = ethereum.chainId

    override fun connect(callback: (MetaMaskTransportResult) -> Unit) =
        ethereum.connect { result ->
            callbackDispatcher.deliver { callback(result.toTransportResult(expectValue = false)) }
        }

    override fun connectSign(messageHex: String, callback: (MetaMaskTransportResult) -> Unit) =
        ethereum.connectSign(messageHex) { result ->
            callbackDispatcher.deliver { callback(result.toTransportResult(expectValue = true)) }
        }

    override fun personalSign(messageHex: String, address: String, callback: (MetaMaskTransportResult) -> Unit) {
        ethereum.personalSign(messageHex, address) { result ->
            callbackDispatcher.deliver { callback(result.toTransportResult(expectValue = true)) }
        }
    }

    override fun disconnect() = ethereum.disconnect(clearSession = true)

    private fun Result.toTransportResult(expectValue: Boolean): MetaMaskTransportResult = when (this) {
        is Result.Success.Item -> if (expectValue) MetaMaskTransportResult.Value(value) else MetaMaskTransportResult.Success
        is Result.Success -> if (expectValue) {
            MetaMaskTransportResult.Failed("MetaMask returned an invalid result")
        } else {
            MetaMaskTransportResult.Success
        }
        is Result.Error -> if (error.code == USER_REJECTED_REQUEST) {
            MetaMaskTransportResult.Cancelled
        } else {
            MetaMaskTransportResult.Failed(error.message ?: "MetaMask request failed")
        }
    }

    private companion object { const val USER_REJECTED_REQUEST = 4001 }
}

/**
 * Direct MetaMask adapter. It never treats a restored hint as a live account;
 * live values are read from the SDK only after a successful callback.
 */
class MetaMaskWalletConnector internal constructor(
    private val transport: MetaMaskTransport,
    private val hintStore: WalletHintStorage,
) : WalletConnector {
    constructor(context: Context) : this(MetaMaskSdkTransport(context), WalletHintStore(context))

    private var generation = 0L
    private var liveAddress: LiveWalletAddress? = null
    private var cachedHint: CachedWalletHint? = hintStore.load()
    private val mutableState = MutableStateFlow<WalletConnectorState>(
        cachedHint?.let(WalletConnectorState::Restored) ?: WalletConnectorState.Idle,
    )
    override val state: StateFlow<WalletConnectorState> = mutableState.asStateFlow()

    override fun connect(callback: (WalletConnectOutcome) -> Unit) {
        val requestGeneration = ++generation
        mutableState.value = WalletConnectorState.Connecting(cachedHint)
        mutableState.value = WalletConnectorState.AwaitingApproval(cachedHint)
        transport.connect { result ->
            if (generation != requestGeneration) return@connect
            when (result) {
                MetaMaskTransportResult.Success -> finishConnected(callback)
                is MetaMaskTransportResult.Value -> finishConnected(callback)
                MetaMaskTransportResult.Cancelled -> finishCancelled(callback)
                is MetaMaskTransportResult.Failed -> finishFailed(if (result.reason.contains("timeout", ignoreCase = true)) WalletBindingFailure.TimedOut else WalletBindingFailure.NotConnected, callback)
            }
        }
    }

    override fun connectAndSign(messageHex: String, callback: (WalletConnectOutcome) -> Unit) {
        val requestGeneration = ++generation
        mutableState.value = WalletConnectorState.Connecting(cachedHint)
        mutableState.value = WalletConnectorState.AwaitingApproval(cachedHint)
        transport.connectSign(messageHex) { result ->
            if (generation != requestGeneration) return@connectSign
            when (result) {
                is MetaMaskTransportResult.Value -> {
                    val live = readLiveAddressOrNull()
                    if (live == null) {
                    finishFailed(WalletBindingFailure.NotConnected, callback)
                    } else {
                        recordLiveAddress(live)
                        callback(WalletConnectOutcome.ConnectedAndSigned(live, result.value))
                    }
                }
                MetaMaskTransportResult.Cancelled -> finishCancelled(callback)
                is MetaMaskTransportResult.Failed -> finishFailed(if (result.reason.contains("timeout", ignoreCase = true)) WalletBindingFailure.TimedOut else WalletBindingFailure.NotConnected, callback)
                MetaMaskTransportResult.Success -> finishFailed(WalletBindingFailure.VerificationFailed, callback)
            }
        }
    }

    override fun personalSign(
        address: LiveWalletAddress,
        messageHex: String,
        callback: (WalletConnectOutcome) -> Unit,
    ) {
        if (liveAddress != address) {
            callback(WalletConnectOutcome.Failed(WalletBindingFailure.NotConnected))
            return
        }
        val requestGeneration = ++generation
        mutableState.value = WalletConnectorState.AwaitingApproval(cachedHint)
        transport.personalSign(messageHex, address.address) { result ->
            if (generation != requestGeneration) return@personalSign
            when (result) {
                is MetaMaskTransportResult.Value -> {
                    mutableState.value = WalletConnectorState.Connected(address)
                    callback(WalletConnectOutcome.Signed(result.value))
                }
                MetaMaskTransportResult.Cancelled -> finishCancelled(callback)
                is MetaMaskTransportResult.Failed -> finishFailed(if (result.reason.contains("timeout", ignoreCase = true)) WalletBindingFailure.TimedOut else WalletBindingFailure.NotConnected, callback)
                MetaMaskTransportResult.Success -> finishFailed(WalletBindingFailure.VerificationFailed, callback)
            }
        }
    }

    /** Invalidates app callbacks without clearing MetaMask's session or the display hint. */
    override fun cancelPendingOperation() {
        generation += 1
        mutableState.value = liveAddress?.let(WalletConnectorState::Connected)
            ?: cachedHint?.let(WalletConnectorState::Restored)
            ?: WalletConnectorState.Idle
    }

    /** Explicit forget operation. No current Android UI calls this API. */
    override fun disconnect() {
        generation += 1
        transport.disconnect()
        liveAddress = null
        cachedHint = null
        hintStore.clear()
        mutableState.value = WalletConnectorState.Idle
    }

    private fun finishConnected(callback: (WalletConnectOutcome) -> Unit) {
        val live = readLiveAddressOrNull()
        if (live == null) {
            finishFailed(WalletBindingFailure.NotConnected, callback)
            return
        }
        recordLiveAddress(live)
        callback(WalletConnectOutcome.Connected(live))
    }

    private fun recordLiveAddress(live: LiveWalletAddress) {
        liveAddress = live
        cachedHint = CachedWalletHint(live.address, live.chainId).also(hintStore::save)
        mutableState.value = WalletConnectorState.Connected(live)
    }

    private fun finishCancelled(callback: (WalletConnectOutcome) -> Unit) {
        cancelPendingOperation()
        callback(WalletConnectOutcome.Cancelled)
    }

    private fun finishFailed(failure: WalletBindingFailure, callback: (WalletConnectOutcome) -> Unit) {
        mutableState.value = WalletConnectorState.Failed(failure.name, cachedHint, liveAddress)
        callback(WalletConnectOutcome.Failed(failure))
    }

    private fun readLiveAddressOrNull(): LiveWalletAddress? {
        val address = transport.selectedAddress.takeIf { it.isNotBlank() } ?: return null
        val chain = parseChainId(transport.chainId) ?: return null
        return LiveWalletAddress.fromConnectorResult(address, chain)
    }

    private fun parseChainId(raw: String): Long? {
        val normalized = raw.trim().lowercase()
        return when {
            normalized.startsWith("eip155:") -> normalized.removePrefix("eip155:").toLongOrNull()
            normalized.startsWith("0x") -> normalized.removePrefix("0x").toLongOrNull(16)
            else -> normalized.toLongOrNull()
        }
    }
}

/** Production caller for the normal connect → sign → verify → owner-ack path. */
class WalletBindingFlow(
    private val coordinator: EventJoinCoordinator,
    private val connector: WalletConnector,
) {
    private var nextAttemptId = 0L
    private var currentAttemptId: Long? = null

    init {
        coordinator.onBindingAttemptInvalidated = {
            currentAttemptId = null
            connector.cancelPendingOperation()
        }
    }

    fun cancel() {
        currentAttemptId = null
        connector.cancelPendingOperation()
        coordinator.declineBinding()
    }

    fun start(onResult: (WalletConnectOutcome) -> Unit = {}) {
        if (currentAttemptId != null) return
        val attemptId = ++nextAttemptId
        currentAttemptId = attemptId
        when (val connectorState = connector.state.value) {
            is WalletConnectorState.Connected -> signConnected(attemptId, connectorState.live, onResult)
            is WalletConnectorState.Restored -> connectAndSignRestored(attemptId, connectorState.hint, onResult)
            is WalletConnectorState.Failed -> connectorState.live?.let {
                signConnected(attemptId, it, onResult)
            } ?: connectorState.hint?.let {
                connectAndSignRestored(attemptId, it, onResult)
            } ?: connectFresh(attemptId, onResult)
            is WalletConnectorState.Idle -> connectFresh(attemptId, onResult)
            is WalletConnectorState.Connecting, is WalletConnectorState.AwaitingApproval -> currentAttemptId = null
        }
    }

    private fun connectFresh(attemptId: Long, onResult: (WalletConnectOutcome) -> Unit) {
        connector.connect { connected ->
            if (currentAttemptId != attemptId) return@connect
            when (connected) {
                is WalletConnectOutcome.Connected -> {
                    signConnected(attemptId, connected.live, onResult)
                }
                is WalletConnectOutcome.Cancelled -> fail(attemptId, WalletBindingFailure.Declined, onResult)
                is WalletConnectOutcome.Failed -> { coordinator.failBinding(connected.failure); finish(onResult, connected) }
                is WalletConnectOutcome.Signed, is WalletConnectOutcome.ConnectedAndSigned ->
                    fail(attemptId, WalletBindingFailure.NotConnected, onResult)
            }
        }
    }

    private fun connectAndSignRestored(
        attemptId: Long,
        hint: CachedWalletHint,
        onResult: (WalletConnectOutcome) -> Unit,
    ) {
        val message = coordinator.beginBinding(hint.address, hint.chainId)
        if (message == null) {
            fail(attemptId, WalletBindingFailure.NotConnected, onResult)
            return
        }
        coordinator.markBindingAwaitingApproval()
        connector.connectAndSign(message) { outcome ->
            if (currentAttemptId != attemptId) return@connectAndSign
            when (outcome) {
                is WalletConnectOutcome.ConnectedAndSigned ->
                    complete(attemptId, outcome.live, outcome.signatureHex, onResult)
                is WalletConnectOutcome.Cancelled -> fail(attemptId, WalletBindingFailure.Declined, onResult)
                is WalletConnectOutcome.Failed -> { coordinator.failBinding(outcome.failure); finish(onResult, outcome) }
                is WalletConnectOutcome.Connected, is WalletConnectOutcome.Signed ->
                    fail(attemptId, WalletBindingFailure.VerificationFailed, onResult)
            }
        }
    }

    private fun signConnected(
        attemptId: Long,
        live: LiveWalletAddress,
        onResult: (WalletConnectOutcome) -> Unit,
    ) {
        val message = coordinator.beginBinding(live.address, live.chainId)
        if (message == null) {
            fail(attemptId, WalletBindingFailure.NotConnected, onResult)
            return
        }
        coordinator.markBindingAwaitingApproval()
        connector.personalSign(live, message) { outcome ->
            if (currentAttemptId != attemptId) return@personalSign
            when (outcome) {
                is WalletConnectOutcome.Signed -> complete(attemptId, live, outcome.signatureHex, onResult)
                is WalletConnectOutcome.Cancelled -> fail(attemptId, WalletBindingFailure.Declined, onResult)
                is WalletConnectOutcome.Failed -> { coordinator.failBinding(outcome.failure); finish(onResult, outcome) }
                is WalletConnectOutcome.Connected, is WalletConnectOutcome.ConnectedAndSigned ->
                    fail(attemptId, WalletBindingFailure.VerificationFailed, onResult)
            }
        }
    }

    private fun complete(
        attemptId: Long,
        live: LiveWalletAddress,
        signatureHex: String,
        onResult: (WalletConnectOutcome) -> Unit,
    ) {
        if (currentAttemptId != attemptId) return
        when (coordinator.completeBinding(live.address, signatureHex)) {
            is BindingCompletionResult.Bound -> finish(onResult, WalletConnectOutcome.Signed(signatureHex))
            BindingCompletionResult.SmartWalletUnsupported ->
                fail(attemptId, WalletBindingFailure.SmartWalletUnsupported, onResult)
            BindingCompletionResult.NotVerified ->
                fail(attemptId, WalletBindingFailure.VerificationFailed, onResult)
        }
    }

    private fun fail(attemptId: Long, failure: WalletBindingFailure, onResult: (WalletConnectOutcome) -> Unit) {
        if (currentAttemptId != attemptId) return
        coordinator.failBinding(failure)
        finish(onResult, WalletConnectOutcome.Failed(failure))
    }

    private fun finish(onResult: (WalletConnectOutcome) -> Unit, result: WalletConnectOutcome) {
        currentAttemptId = null
        onResult(result)
    }
}
