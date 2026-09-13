package org.levarac.beid.sensing

import android.content.Context
import io.metamask.androidsdk.DappMetadata
import io.metamask.androidsdk.Ethereum
import io.metamask.androidsdk.Result

sealed class WalletConnectOutcome {
    data class Connected(val address: String, val chainId: Long) : WalletConnectOutcome()
    data class Signed(val signatureHex: String) : WalletConnectOutcome()
    data object Cancelled : WalletConnectOutcome()
    data class Failed(val reason: String) : WalletConnectOutcome()
}

interface WalletConnector {
    fun connect(callback: (WalletConnectOutcome) -> Unit)
    fun personalSign(address: String, messageHex: String, callback: (WalletConnectOutcome) -> Unit)
}

/** Thin native MetaMask adapter. It exposes only account selection and personal_sign. */
class MetaMaskWalletConnector(context: Context) : WalletConnector {
    private val ethereum = Ethereum(
        context = context.applicationContext,
        dappMetadata = DappMetadata("Beid", "https://beid.levarac.org"),
    )

    override fun connect(callback: (WalletConnectOutcome) -> Unit) {
        ethereum.connect { result ->
            when (result) {
                is Result.Success -> {
                    val address = ethereum.selectedAddress
                    val chainId = ethereum.chainId.removePrefix("0x").toLongOrNull(16)
                    if (address.isBlank() || chainId == null) {
                        callback(WalletConnectOutcome.Failed("MetaMask returned no account or chain"))
                    } else callback(WalletConnectOutcome.Connected(address, chainId))
                }
                is Result.Error -> callback(result.toOutcome())
            }
        }
    }

    override fun personalSign(address: String, messageHex: String, callback: (WalletConnectOutcome) -> Unit) {
        ethereum.personalSign(messageHex, address) { result ->
            when (result) {
                is Result.Success.Item -> callback(WalletConnectOutcome.Signed(result.value))
                is Result.Success -> callback(WalletConnectOutcome.Failed("MetaMask returned an invalid signing result"))
                is Result.Error -> callback(result.toOutcome())
            }
        }
    }

    private fun Result.Error.toOutcome(): WalletConnectOutcome =
        if (error.code == USER_REJECTED_REQUEST) WalletConnectOutcome.Cancelled
        else WalletConnectOutcome.Failed(error.message ?: "MetaMask request failed")

    private companion object { const val USER_REJECTED_REQUEST = 4001 }
}

/** Production caller for the normal connect → sign → verify → owner-ack path. */
class WalletBindingFlow(
    private val coordinator: EventJoinCoordinator,
    private val connector: WalletConnector,
) {
    private var nextAttemptId = 0L
    private var currentAttemptId: Long? = null

    init { coordinator.onBindingAttemptInvalidated = { currentAttemptId = null } }

    fun cancel() {
        currentAttemptId = null
        coordinator.declineBinding()
    }

    fun start(onResult: (WalletConnectOutcome) -> Unit = {}) {
        if (currentAttemptId != null) return
        val attemptId = ++nextAttemptId
        currentAttemptId = attemptId
        connector.connect { connected ->
            if (currentAttemptId != attemptId) return@connect
            when (connected) {
                is WalletConnectOutcome.Connected -> {
                    val message = coordinator.beginBinding(connected.address, connected.chainId)
                    if (message == null) {
                        coordinator.failBinding("Wallet binding is unavailable while recording")
                        finish(onResult, WalletConnectOutcome.Failed("Wallet binding is unavailable while recording"))
                        return@connect
                    }
                    coordinator.markBindingAwaitingApproval()
                    connector.personalSign(connected.address, message) { signed ->
                        if (currentAttemptId != attemptId) return@personalSign
                        when (signed) {
                            is WalletConnectOutcome.Signed -> {
                                if (coordinator.completeBinding(connected.address, signed.signatureHex) == null) {
                                    coordinator.failBinding("Wallet signature did not pass Barnard verification")
                                    finish(onResult, WalletConnectOutcome.Failed("Wallet signature did not pass Barnard verification"))
                                } else finish(onResult, signed)
                            }
                            is WalletConnectOutcome.Cancelled -> {
                                coordinator.declineBinding()
                                finish(onResult, signed)
                            }
                            is WalletConnectOutcome.Failed -> {
                                coordinator.failBinding(signed.reason)
                                finish(onResult, signed)
                            }
                            is WalletConnectOutcome.Connected -> finish(onResult, WalletConnectOutcome.Failed("MetaMask returned an invalid signing result"))
                        }
                    }
                }
                is WalletConnectOutcome.Cancelled -> { coordinator.declineBinding(); finish(onResult, connected) }
                is WalletConnectOutcome.Failed -> { coordinator.failBinding(connected.reason); finish(onResult, connected) }
                is WalletConnectOutcome.Signed -> finish(onResult, WalletConnectOutcome.Failed("MetaMask returned an invalid account result"))
            }
        }
    }

    private fun finish(onResult: (WalletConnectOutcome) -> Unit, result: WalletConnectOutcome) {
        currentAttemptId = null
        onResult(result)
    }
}
