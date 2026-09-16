package org.levarac.beid.sensing

import android.content.Context

/**
 * Display-only record of the last account the live MetaMask SDK reported.
 *
 * This is deliberately not a [LiveWalletAddress] and has no conversion to
 * one. A process restored from this value must ask MetaMask again before an
 * address can reach `EventJoinCoordinator.completeBinding`.
 */
data class CachedWalletHint(
    val address: String,
    val chainId: Long,
) {
    val truncatedAddress: String
        get() = if (address.length <= 10) address else "${address.take(6)}...${address.takeLast(4)}"
}

interface WalletHintStorage {
    fun load(): CachedWalletHint?
    fun save(hint: CachedWalletHint)
    fun clear()
}

/** Ordinary SharedPreferences storage: a public wallet address is not a secret. */
class WalletHintStore(context: Context) : WalletHintStorage {
    private val preferences = context.applicationContext.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    override fun load(): CachedWalletHint? {
        val address = preferences.getString(KEY_ADDRESS, null)?.takeIf { it.isNotBlank() } ?: return null
        if (!preferences.contains(KEY_CHAIN_ID)) return null
        return CachedWalletHint(address, preferences.getLong(KEY_CHAIN_ID, 0L))
    }

    override fun save(hint: CachedWalletHint) {
        preferences.edit()
            .putString(KEY_ADDRESS, hint.address)
            .putLong(KEY_CHAIN_ID, hint.chainId)
            .apply()
    }

    override fun clear() {
        preferences.edit().remove(KEY_ADDRESS).remove(KEY_CHAIN_ID).apply()
    }

    private companion object {
        const val PREFERENCES_NAME = "beid_wallet_hint"
        const val KEY_ADDRESS = "last_connected_address"
        const val KEY_CHAIN_ID = "last_connected_chain_id"
    }
}
