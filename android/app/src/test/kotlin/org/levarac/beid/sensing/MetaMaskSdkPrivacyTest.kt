package org.levarac.beid.sensing

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import io.metamask.androidsdk.CommunicationClientModule
import io.metamask.androidsdk.Encryption
import io.metamask.androidsdk.Ethereum
import io.metamask.androidsdk.Event
import io.metamask.androidsdk.KeyExchange
import io.metamask.androidsdk.SecureStorage
import io.metamask.androidsdk.Tracker
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class MetaMaskSdkPrivacyTest {
    @Test
    fun productionTransportDisablesSdkTrackingBeforeAnyWalletOperation() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val module = TestModule(context)
        val transport = MetaMaskSdkTransport(context, module)
        // Inspect the SDK instance owned by the production transport, not a
        // separate configuration object that its constructor could ignore.
        val ethereum = MetaMaskSdkTransport::class.java.getDeclaredField("ethereum")
            .apply { isAccessible = true }.get(transport) as Ethereum

        assertFalse(ethereum.enableDebug, "SDK debug/tracking must be explicitly disabled")
        assertFalse(assertNotNull(ethereum.communicationClient).enableDebug)
        val tracker = assertNotNull(module.tracker)
        assertFalse(tracker.enableDebug, "The setting must reach the real SDK Analytics instance")

        // SDK 0.6.6 Analytics.trackEvent adds this key immediately before its
        // HTTPS call. A disabled tracker must return before either operation.
        // Check the flag first so a regression fails without sending analytics.
        for (event in Event.values()) {
            val params = mutableMapOf<String, String>()
            tracker.trackEvent(event, params)
            assertFalse(params.containsKey("event"), "Analytics processed ${event.name}")
        }
    }

    /** Keep the real SDK client and Analytics; replace only device dependencies. */
    private class TestModule(context: Context) : CommunicationClientModule(context) {
        var tracker: Tracker? = null
            private set

        override fun provideTracker(): Tracker = super.provideTracker().also { tracker = it }

        override fun provideKeyStorage(): SecureStorage = object : SecureStorage {
            override fun loadSecretKey() = Unit
            override suspend fun getValue(key: String, file: String): String? = null
            override fun putValue(value: String, key: String, file: String) = Unit
            override fun clear(file: String) = Unit
            override fun clearValue(key: String, file: String) = Unit
        }

        override fun provideKeyExchange(): KeyExchange = KeyExchange(object : Encryption {
            override var onInitialized: () -> Unit = {}
            override fun generatePrivateKey(): String = "test-private-key"
            override fun publicKey(privateKey: String): String = "test-public-key"
            override fun encrypt(publicKey: String, message: String): String = error("No wallet operation expected")
            override fun decrypt(privateKey: String, message: String): String = error("No wallet operation expected")
        })
    }
}
