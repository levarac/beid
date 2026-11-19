package org.levarac.beid.sensing

import androidx.compose.runtime.Stable
import androidx.compose.runtime.staticCompositionLocalOf
import kotlinx.coroutines.flow.StateFlow

/**
 * What Home's inline Bluetooth-off block needs — integration/ios-1.1.1
 * `ios/Beid/Views/CollectionHomeView.swift:244-264` ("BLUETOOTH OFF · SENSING PAUSED" with
 * FIX and OPEN SETTINGS), shown in standby (`:186`) and above an active
 * session summary (`:84`). This type only supplies state and actions; the
 * block itself belongs to the Home surface.
 *
 * @property isRadioOff iOS's `homeBluetoothIsOff` (same branch, `AppCoordinator.swift:918-924`):
 *   true only while authorized and powered off. Emits on the main thread.
 * @property onFix FIX: opens the Bluetooth-off screen (`CollectionHomeView.swift:249-251`,
 *   `coordinator.screen = .bluetoothOff`). Main thread.
 * @property onOpenSettings OPEN SETTINGS: the same Bluetooth-settings intent the
 *   Bluetooth-off screen's "Open Settings" starts (`CollectionHomeView.swift:258-262`). Main thread.
 */
@Stable
class HomeBluetoothStatus(
    val isRadioOff: StateFlow<Boolean>,
    val onFix: () -> Unit,
    val onOpenSettings: () -> Unit,
)

/**
 * Provided by `AppNavHost` around every destination. `null` outside it (a
 * screen composed directly by a test or preview), where a consumer shows no
 * block.
 */
val LocalHomeBluetoothStatus = staticCompositionLocalOf<HomeBluetoothStatus?> { null }
