package org.levarac.beid.sensing

import android.bluetooth.BluetoothAdapter
import android.content.Context
import android.content.Intent
import androidx.test.core.app.ApplicationProvider
import kotlin.test.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class BluetoothStateMonitorTest {
    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private val shadowAdapter get() = shadowOf(BluetoothAdapter.getDefaultAdapter())

    @Test
    fun startedMonitorFollowsRadioStateBroadcasts() {
        shadowAdapter.setEnabled(true)
        val monitor = BluetoothStateMonitor(context) { BluetoothPermissionState.Granted }
        monitor.start()
        assertEquals(BluetoothAvailability.Ready, monitor.availability.value)
        assertEquals(true, monitor.state.value.radioOn)

        shadowAdapter.setEnabled(false)
        broadcastRadioState(BluetoothAdapter.STATE_OFF)
        assertEquals(BluetoothAvailability.PoweredOff, monitor.availability.value)

        shadowAdapter.setEnabled(true)
        broadcastRadioState(BluetoothAdapter.STATE_ON)
        assertEquals(BluetoothAvailability.Ready, monitor.availability.value)
        monitor.stop()
    }

    /** The adapter reports "not on" as soon as it starts turning off; so does this monitor. */
    @Test
    fun turningOffAlreadyCountsAsOff() {
        shadowAdapter.setEnabled(true)
        val monitor = BluetoothStateMonitor(context) { BluetoothPermissionState.Granted }
        monitor.start()

        broadcastRadioState(BluetoothAdapter.STATE_TURNING_OFF)

        assertEquals(BluetoothAvailability.PoweredOff, monitor.availability.value)
        monitor.stop()
    }

    @Test
    fun refreshRereadsPermissionAndRadio() {
        shadowAdapter.setEnabled(true)
        var permission = BluetoothPermissionState.Denied
        val monitor = BluetoothStateMonitor(context) { permission }
        monitor.start()
        assertEquals(BluetoothAvailability.Denied, monitor.availability.value)

        permission = BluetoothPermissionState.Granted
        shadowAdapter.setEnabled(false)
        monitor.refresh()

        assertEquals(BluetoothAvailability.PoweredOff, monitor.availability.value)
        monitor.stop()
    }

    /**
     * The Home inline block's flag mirrors integration/ios-1.1.1
     * `AppCoordinator.swift:918-924` (`homeBluetoothIsOff` =
     * `bluetoothMonitor.isPoweredOff`): authorized and powered off only.
     */
    @Test
    fun isRadioOffIsTrueOnlyWhileAuthorizedAndPoweredOff() {
        shadowAdapter.setEnabled(true)
        var permission = BluetoothPermissionState.Granted
        val monitor = BluetoothStateMonitor(context) { permission }
        monitor.start()
        assertEquals(false, monitor.isRadioOff.value)

        shadowAdapter.setEnabled(false)
        broadcastRadioState(BluetoothAdapter.STATE_OFF)
        assertEquals(true, monitor.isRadioOff.value)

        permission = BluetoothPermissionState.Denied
        monitor.refresh()
        assertEquals(false, monitor.isRadioOff.value, "denied is its own guidance, not 'radio off'")

        permission = BluetoothPermissionState.Granted
        shadowAdapter.setEnabled(true)
        broadcastRadioState(BluetoothAdapter.STATE_ON)
        assertEquals(false, monitor.isRadioOff.value)
        monitor.stop()
    }

    @Test
    fun stoppedMonitorIgnoresBroadcasts() {
        shadowAdapter.setEnabled(true)
        val monitor = BluetoothStateMonitor(context) { BluetoothPermissionState.Granted }
        monitor.start()
        monitor.stop()

        broadcastRadioState(BluetoothAdapter.STATE_OFF)

        assertEquals(BluetoothAvailability.Ready, monitor.availability.value)
    }

    private fun broadcastRadioState(state: Int) {
        context.sendBroadcast(
            Intent(BluetoothAdapter.ACTION_STATE_CHANGED).putExtra(BluetoothAdapter.EXTRA_STATE, state),
        )
        ShadowLooper.idleMainLooper()
    }
}
