package org.levarac.beid.sensing

import android.os.Looper
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import kotlin.test.Test
import kotlin.test.assertEquals
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class MainThreadWalletCallbackDispatcherTest {
    @Test
    fun binderStyleBackgroundCallbackIsDeliveredOnMainLooper() {
        val dispatcher = MainThreadWalletCallbackDispatcher()
        val deliveredLooper = AtomicReference<Looper?>()

        thread(name = "fake-metamask-aidl-callback") {
            dispatcher.deliver { deliveredLooper.set(Looper.myLooper()) }
        }.join()
        shadowOf(Looper.getMainLooper()).idle()

        assertEquals(Looper.getMainLooper(), deliveredLooper.get())
    }
}
