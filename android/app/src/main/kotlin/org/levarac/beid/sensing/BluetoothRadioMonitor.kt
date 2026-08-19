package org.levarac.beid.sensing

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.Context

/**
 * Android's Bluetooth radio-power signal for onboarding routing — the
 * counterpart of iOS's `BluetoothMonitor.isPoweredOff`
 * (`AppCoordinator.evaluateBluetoothState()`). Android's adapter-enabled
 * check is synchronous, unlike iOS's async `CBCentralManagerDelegate`
 * callback, so no start()/delegate dance is needed here.
 */
class BluetoothRadioMonitor(context: Context) {
    private val adapter: BluetoothAdapter? =
        context.getSystemService(BluetoothManager::class.java)?.adapter

    /** `false` (fail-safe "not on") when there is no adapter at all, e.g. no BLE hardware. */
    val isOn: Boolean get() = adapter?.isEnabled == true
}
