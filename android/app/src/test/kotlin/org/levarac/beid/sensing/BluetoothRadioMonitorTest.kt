package org.levarac.beid.sensing

import android.bluetooth.BluetoothAdapter
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class BluetoothRadioMonitorTest {
    @Test
    fun isOnReflectsTheAdaptersEnabledState() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val shadowAdapter = shadowOf(BluetoothAdapter.getDefaultAdapter())

        shadowAdapter.setEnabled(true)
        assertTrue(BluetoothRadioMonitor(context).isOn)

        shadowAdapter.setEnabled(false)
        assertFalse(BluetoothRadioMonitor(context).isOn)
    }
}
