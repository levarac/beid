package org.levarac.beid.sensing

import android.os.Handler
import android.os.Looper

/**
 * Main-thread boundary for MetaMask SDK responses.
 *
 * Verified against the resolved `metamask-android-sdk:0.6.6` bytecode: its
 * response arrives through an AIDL Stub and invokes the stored request
 * callback inline, with no SDK main-thread marshal. Wallet flow/coordinator
 * state is main-thread-owned, so production transport callbacks cross this
 * helper before touching connector, coordinator, or persistence state.
 */
internal class MainThreadWalletCallbackDispatcher(
    private val handler: Handler = Handler(Looper.getMainLooper()),
) {
    fun deliver(callback: () -> Unit) {
        if (Looper.myLooper() == handler.looper) callback() else handler.post(callback)
    }
}
