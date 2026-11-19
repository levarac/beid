package org.levarac.beid.sensing

import android.bluetooth.BluetoothAdapter
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import androidx.core.content.ContextCompat
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** The two inputs Bluetooth routing reads. */
data class BluetoothRuntimeState(val permission: BluetoothPermissionState, val radioOn: Boolean) {
    val availability: BluetoothAvailability get() = bluetoothAvailabilityOf(permission, radioOn)
}

/**
 * Live Bluetooth permission and radio state while the app runs — Android's
 * counterpart of iOS's `BluetoothMonitor` `@Published state`
 * (integration/ios-1.1.1 `ios/Beid/Sensing/BluetoothMonitor.swift:21,45-71`).
 *
 * The radio follows [BluetoothAdapter.ACTION_STATE_CHANGED] while started.
 * Android has no broadcast for a permission change, so [refresh] re-reads it;
 * the host calls that on every resume, which is when a change made in
 * Settings becomes visible.
 *
 * Main thread only: [start], [stop] and [refresh] must be called on the main
 * thread, and the receiver runs there, so every flow emits on the main thread.
 */
class BluetoothStateMonitor(
    context: Context,
    private val readRadioOn: () -> Boolean = BluetoothRadioMonitor(context)::isOn,
    private val readPermission: () -> BluetoothPermissionState,
) {
    private val appContext = context.applicationContext
    private val mutableState = MutableStateFlow(read())
    private val mutableAvailability = MutableStateFlow(mutableState.value.availability)
    private val mutableIsRadioOff = MutableStateFlow(mutableState.value.isRadioOff())
    private var registered = false

    val state: StateFlow<BluetoothRuntimeState> = mutableState.asStateFlow()
    val availability: StateFlow<BluetoothAvailability> = mutableAvailability.asStateFlow()

    /**
     * True only while authorized and powered off — iOS's `homeBluetoothIsOff`
     * (integration/ios-1.1.1 `ios/Beid/Navigation/AppCoordinator.swift:918-924`, which
     * is `BluetoothMonitor.isPoweredOff`, `ios/Beid/Sensing/BluetoothMonitor.swift:23`). A denied
     * app is never "radio off": it has its own guidance.
     */
    val isRadioOff: StateFlow<Boolean> = mutableIsRadioOff.asStateFlow()

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
            // The extra is authoritative for the transition being announced;
            // the adapter itself already reports "not on" from TURNING_OFF.
            val radioOn = when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, UNKNOWN_STATE)) {
                BluetoothAdapter.STATE_ON -> true
                UNKNOWN_STATE -> readRadioOn()
                else -> false
            }
            publish(mutableState.value.copy(radioOn = radioOn))
        }
    }

    fun start() {
        if (registered) return
        // ACTION_STATE_CHANGED is a protected broadcast sent by the Bluetooth
        // stack's own process, not by the system UID, so a NOT_EXPORTED
        // receiver may never see it. Only the platform can send it.
        ContextCompat.registerReceiver(
            appContext,
            receiver,
            IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED),
            ContextCompat.RECEIVER_EXPORTED,
        )
        registered = true
        refresh()
    }

    fun stop() {
        if (!registered) return
        appContext.unregisterReceiver(receiver)
        registered = false
    }

    /** Re-reads both inputs: call on resume and whenever a route needs a fresh answer. */
    fun refresh() = publish(read())

    private fun read() = BluetoothRuntimeState(permission = readPermission(), radioOn = readRadioOn())

    private fun publish(next: BluetoothRuntimeState) {
        mutableState.value = next
        mutableAvailability.value = next.availability
        mutableIsRadioOff.value = next.isRadioOff()
    }

    private fun BluetoothRuntimeState.isRadioOff() = availability == BluetoothAvailability.PoweredOff

    private companion object {
        const val UNKNOWN_STATE = Int.MIN_VALUE
    }
}
