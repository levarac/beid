package org.levarac.beid

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import org.levarac.beid.navigation.AppNavHost
import org.levarac.beid.sensing.EventJoinCoordinator
import org.levarac.beid.ui.theme.BeidAppTheme

/**
 * Single-activity Compose host — the Android equivalent of iOS's
 * `BeidApp` + `RootView` (`ios/Beid/App/BeidApp.swift`,
 * `ios/Beid/Navigation/RootView.swift`).
 *
 * Owns [EventJoinCoordinator] (rather than letting a composable create it)
 * because `BarnardEngine.requestPermissions` needs this Activity's
 * `onRequestPermissionsResult` forwarded back into the same engine instance
 * to resolve — see [EventJoinCoordinator]'s kdoc.
 */
class MainActivity : ComponentActivity() {
    private lateinit var eventJoinCoordinator: EventJoinCoordinator

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        eventJoinCoordinator = EventJoinCoordinator(this)
        setContent {
            BeidAppTheme {
                AppNavHost(eventJoinCoordinator)
            }
        }
    }

    // BarnardEngine.requestPermissions is built on the classic
    // onRequestPermissionsResult callback (not ActivityResultContracts).
    // Deliberate, not migration debt.
    @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        eventJoinCoordinator.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun onDestroy() {
        eventJoinCoordinator.dispose()
        super.onDestroy()
    }
}
