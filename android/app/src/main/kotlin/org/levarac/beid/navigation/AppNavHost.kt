package org.levarac.beid.navigation

import android.content.Intent
import android.provider.Settings
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import org.levarac.beid.onboarding.OnboardingPreferences
import org.levarac.beid.persistence.ProofRecordStore
import org.levarac.beid.sensing.BluetoothRadioMonitor
import org.levarac.beid.sensing.EventJoinSession
import org.levarac.beid.ui.screens.AccountRoute
import org.levarac.beid.ui.screens.BluetoothOffScreen
import org.levarac.beid.ui.screens.BluetoothPermissionScreen
import org.levarac.beid.ui.screens.EventJoinRoute
import org.levarac.beid.ui.screens.RecordsRoute
import org.levarac.beid.ui.screens.WelcomeScreen

/**
 * Root navigation scaffold — the Compose-Navigation equivalent of iOS's
 * `RootView` + `AppCoordinator`. Onboarding (Welcome → BluetoothPermission →
 * Home/BluetoothOff) mirrors `AppCoordinator`'s guestFirst path
 * (`beginOnboarding()` → `requestBluetoothPermission()` →
 * `evaluateBluetoothState()`); [Screen.EventJoin] stands in for "Home".
 *
 * Start-destination resolution mirrors iOS's #194 restore fix
 * (`AppCoordinator.restoreAfterOnboarding()`): a user who already completed
 * onboarding but whose radio is now off must land on [Screen.BluetoothOff],
 * not be dropped on Home with a dead radio.
 */
@Composable
fun AppNavHost(session: EventJoinSession, proofRecordStore: ProofRecordStore) {
    val context = LocalContext.current
    val navController = rememberNavController()
    val onboardingPreferences = remember { OnboardingPreferences(context) }
    val radioMonitor = remember { BluetoothRadioMonitor(context) }

    val startDestination = remember {
        when {
            !onboardingPreferences.hasCompletedOnboarding -> Screen.Welcome.route
            !radioMonitor.isOn -> Screen.BluetoothOff.route
            else -> Screen.EventJoin.route
        }
    }

    NavHost(navController = navController, startDestination = startDestination) {
        composable(Screen.Welcome.route) {
            WelcomeScreen(
                onGetStarted = { navController.navigate(Screen.BluetoothPermission.route) },
            )
        }

        composable(Screen.BluetoothPermission.route) {
            BluetoothPermissionScreen(
                onAllowBluetooth = {
                    session.requestBluetoothPermission {
                        onboardingPreferences.hasCompletedOnboarding = true
                        val next = if (radioMonitor.isOn) Screen.EventJoin.route else Screen.BluetoothOff.route
                        navigateClearingOnboarding(navController, next)
                    }
                },
            )
        }

        composable(Screen.BluetoothOff.route) {
            BluetoothOffScreen(
                onOpenSettings = {
                    context.startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS))
                },
                onTurnedOn = {
                    if (radioMonitor.isOn) {
                        navigateClearingOnboarding(navController, Screen.EventJoin.route)
                    }
                    // Still off: no-op, stay on this screen — matches iOS, which
                    // doesn't message failure either.
                },
            )
        }

        composable(Screen.EventJoin.route) {
            EventJoinRoute(
                session,
                onOpenAccount = { navController.navigate(Screen.Account.route) },
            )
        }

        composable(Screen.Account.route) {
            AccountRoute(session, onOpenRecords = { navController.navigate(Screen.Records.route) })
        }

        composable(Screen.Records.route) {
            RecordsRoute(proofRecordStore)
        }
    }
}

/**
 * Clears the *entire* back stack on the way to a terminal onboarding screen
 * (Home or BluetoothOff) — matches iOS's root-switch, no-back-stack shape for
 * onboarding (`AppCoordinator.screen` is a single published root switch, not
 * a navigation push), so the system back button can never reopen any prior
 * onboarding screen.
 *
 * Pops the whole graph (`navController.graph.id`), not just up to
 * `Screen.Welcome.route`: this function fires on more than one hop (e.g.
 * BluetoothPermission → BluetoothOff → EventJoin), and by the second hop
 * `Welcome` is no longer on the back stack at all, so a `popUpTo(Welcome)`
 * would silently no-op there and leave `BluetoothOff` stranded underneath
 * `EventJoin`.
 */
private fun navigateClearingOnboarding(navController: NavHostController, route: String) {
    navController.navigate(route) {
        popUpTo(navController.graph.id) { inclusive = true }
    }
}
