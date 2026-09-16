package org.levarac.beid.sensing

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class WalletHintStoreTest {
    private val context: Context get() = ApplicationProvider.getApplicationContext()

    @BeforeTest
    @AfterTest
    fun clearStore() {
        WalletHintStore(context).clear()
    }

    @Test
    fun freshStoreInstanceRestoresAddressAndChainWrittenByPreviousInstance() {
        val hint = CachedWalletHint("0x" + "ab".repeat(20), 8453L)
        WalletHintStore(context).save(hint)

        assertEquals(hint, WalletHintStore(context).load())
    }

    @Test
    fun clearRemovesBothAddressAndChain() {
        WalletHintStore(context).save(CachedWalletHint("0x1234", 1L))

        WalletHintStore(context).clear()

        assertNull(WalletHintStore(context).load())
    }
}
