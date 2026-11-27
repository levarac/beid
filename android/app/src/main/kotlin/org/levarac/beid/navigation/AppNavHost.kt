package org.levarac.beid.navigation

import android.content.Intent
import android.content.ActivityNotFoundException
import android.widget.Toast
import android.provider.Settings
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import java.util.UUID
import org.levarac.beid.onboarding.OnboardingPreferences
import org.levarac.beid.persistence.ProofRecordStore
import org.levarac.beid.persistence.SessionAggregateSnapshotStore
import org.levarac.beid.persistence.SigilPresenceStore
import org.levarac.beid.sensing.BluetoothPermissionState
import org.levarac.beid.sensing.BluetoothRadioMonitor
import org.levarac.beid.sensing.BluetoothRouteScreen
import org.levarac.beid.sensing.BluetoothRouteTarget
import org.levarac.beid.sensing.BluetoothStateMonitor
import org.levarac.beid.sensing.HomeBluetoothStatus
import org.levarac.beid.sensing.LocalHomeBluetoothStatus
import org.levarac.beid.sensing.bluetoothRouteFor
import org.levarac.beid.sensing.EventJoinSession
import org.levarac.beid.sensing.WalletConnectorState
import org.levarac.beid.ui.screens.AccountRoute
import org.levarac.beid.ui.screens.BluetoothDeniedScreen
import org.levarac.beid.ui.screens.BluetoothOffScreen
import org.levarac.beid.ui.screens.BluetoothPermissionScreen
import org.levarac.beid.ui.screens.HomeRoute
import org.levarac.beid.ui.screens.ManualEventCodeRoute
import org.levarac.beid.ui.screens.RecordDetailRoute
import org.levarac.beid.ui.screens.RecordsByEventRoute
import org.levarac.beid.ui.screens.RecordsRoute
import org.levarac.beid.ui.screens.TodaySummaryRoute
import org.levarac.beid.ui.screens.WelcomeScreen
import org.levarac.beid.venue.VenueActivity
import org.levarac.beid.R
import org.levarac.beid.support.SupportDiagnostics
import org.levarac.beid.support.supportShareIntent

/**
 * Root navigation scaffold — the Compose-Navigation equivalent of iOS's
 * `RootView` + `AppCoordinator`. Onboarding (Welcome → BluetoothPermission →
 * Home/BluetoothOff/BluetoothDenied) mirrors `AppCoordinator`'s guestFirst path
 * (`beginOnboarding()` → `requestBluetoothPermission()` →
 * `evaluateBluetoothState()`). [Screen.Home] is the Now / Records tab shell of
 * iOS #795; nearby discovery runs only while its Now tab is visible and active.
 *
 * Start-destination resolution mirrors iOS's #194 restore fix
 * (`AppCoordinator.restoreAfterOnboarding()`): a user who already completed
 * onboarding but whose radio is now off must land on [Screen.BluetoothOff],
 * not be dropped on Home with a dead radio.
 */
@Composable
fun AppNavHost(
    session: EventJoinSession,
    proofRecordStore: ProofRecordStore,
    sessionAggregateSnapshotStore: SessionAggregateSnapshotStore? = null,
    sigilPresenceStore: SigilPresenceStore? = null,
    walletState: WalletConnectorState = WalletConnectorState.Idle,
    onStartWalletBinding: () -> Unit = {},
) {
    val context = LocalContext.current
    val navController = rememberNavController()
    val onboardingPreferences = remember { OnboardingPreferences(context) }
    val radioMonitor = remember { BluetoothRadioMonitor(context) }
    val supportDiagnostics: SupportDiagnostics = viewModel()
    LaunchedEffect(session) {
        session.state.collect { supportDiagnostics.accept(it) }
    }

    val startDestination = remember {
        when {
            !onboardingPreferences.hasCompletedOnboarding -> Screen.Welcome.route
            session.bluetoothPermissionState == BluetoothPermissionState.Denied -> Screen.BluetoothDenied.route
            !radioMonitor.isOn -> Screen.BluetoothOff.route
            else -> Screen.Home.route
        }
    }

    val handleBluetoothPermissionResult: (BluetoothPermissionState) -> Unit = { permissionState ->
        when (permissionState) {
            BluetoothPermissionState.Denied -> {
                onboardingPreferences.hasCompletedOnboarding = true
                navigateClearingOnboarding(navController, Screen.BluetoothDenied.route)
            }
            BluetoothPermissionState.NotDetermined -> Unit
            BluetoothPermissionState.Granted -> {
                onboardingPreferences.hasCompletedOnboarding = true
                val next = if (radioMonitor.isOn) Screen.Home.route else Screen.BluetoothOff.route
                navigateClearingOnboarding(navController, next)
            }
        }
    }

    val currentPermissionResultHandler by rememberUpdatedState(handleBluetoothPermissionResult)
    DisposableEffect(session) {
        session.bindBluetoothPermissionResult { currentPermissionResultHandler(it) }
        onDispose { session.bindBluetoothPermissionResult(null) }
    }

    // Live Bluetooth state after onboarding. The decision is
    // `bluetoothRouteFor`; this only feeds it and performs the route.
    val currentSession by rememberUpdatedState(session)
    val bluetoothState = remember { BluetoothStateMonitor(context) { currentSession.refreshBluetoothPermissionState() } }
    DisposableEffect(bluetoothState) {
        bluetoothState.start()
        onDispose { bluetoothState.stop() }
    }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { bluetoothState.refresh() }
    val currentRoute = navController.currentBackStackEntryAsState().value?.destination?.route
    val availability by bluetoothState.availability.collectAsState()
    LaunchedEffect(currentRoute, availability) {
        val screen = bluetoothRouteScreenOf(currentRoute) ?: return@LaunchedEffect
        // A restored back stack or a route change may predate the last read.
        bluetoothState.refresh()
        val target = bluetoothRouteFor(screen, bluetoothState.availability.value) ?: return@LaunchedEffect
        navigateClearingOnboarding(navController, target.route)
    }
    val radioOn = bluetoothState.state.collectAsState().value.radioOn
    LaunchedEffect(session, radioOn) { session.onBluetoothRadioChanged(radioOn) }

    val openBluetoothSettings: () -> Unit = {
        context.startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS))
    }
    val homeBluetoothStatus = remember(bluetoothState) {
        HomeBluetoothStatus(
            isRadioOff = bluetoothState.isRadioOff,
            // iOS sets `coordinator.screen = .bluetoothOff`, a root switch,
            // so Home is not kept underneath; "I've turned it on" returns
            // to a fresh Home the same way onboarding reaches it.
            onFix = { navigateClearingOnboarding(navController, Screen.BluetoothOff.route) },
            onOpenSettings = openBluetoothSettings,
        )
    }

    CompositionLocalProvider(LocalHomeBluetoothStatus provides homeBluetoothStatus) {
        NavHost(navController = navController, startDestination = startDestination) {
            composable(Screen.Welcome.route) {
                WelcomeScreen(
                    onGetStarted = { navController.navigate(Screen.BluetoothPermission.route) },
                )
            }

            composable(Screen.BluetoothPermission.route) {
                BluetoothPermissionScreen(
                    onAllowBluetooth = {
                        session.requestBluetoothPermission(handleBluetoothPermissionResult)
                    },
                )
            }

            composable(Screen.BluetoothDenied.route) {
                BluetoothDeniedScreen(
                    onOpenSettings = { session.openAppSettings() },
                    onCheckAgain = {
                        session.requestBluetoothPermission(handleBluetoothPermissionResult)
                    },
                )
            }

            composable(Screen.BluetoothOff.route) {
                BluetoothOffScreen(
                    onOpenSettings = openBluetoothSettings,
                    onTurnedOn = {
                        if (radioMonitor.isOn) {
                            navigateClearingOnboarding(navController, Screen.Home.route)
                        }
                        // Still off: no-op, stay on this screen — matches iOS, which
                        // doesn't message failure either.
                    },
                )
            }

            composable(Screen.EventJoin.route) {
                LaunchedEffect(Unit) {
                    navController.navigate(Screen.Home.route) {
                        popUpTo(Screen.EventJoin.route) { inclusive = true }
                        launchSingleTop = true
                    }
                }
            }

            composable(Screen.Home.route) {
                HomeRoute(
                    session,
                    proofRecordStore,
                    onOpenAccount = { navController.navigate(Screen.Account.route) },
                    onOpenEventCodeEntry = { navController.navigate(Screen.HomeEventCode.route) },
                    onOpenRecord = { navController.navigate(Screen.RecordDetail.route(it)) },
                    onOpenToday = { navController.navigate(Screen.TodaySummary.route) },
                    onOpenByEvent = { navController.navigate(Screen.RecordsByEvent.route) },
                    onStartWalletBinding = onStartWalletBinding,
                    sigilPresenceStore = sigilPresenceStore,
                )
            }

            composable(Screen.Account.route) {
                val supportShareTitle = stringResource(R.string.account_support_share)
                AccountRoute(
                    onOpenRecords = { navController.navigate(Screen.Records.route) },
                    onOpenManualEventCode = { navController.navigate(Screen.ManualEventCode.route) },
                    walletState = walletState,
                    onOpenVenue = { context.startActivity(VenueActivity.createIntent(context)) },
                    onShareSupport = {
                        try {
                            context.startActivity(supportShareIntent(
                                supportDiagnostics.exportJson(),
                                supportShareTitle,
                            ))
                        } catch (_: ActivityNotFoundException) {
                            Toast.makeText(context, R.string.account_support_unavailable, Toast.LENGTH_LONG).show()
                        }
                    },
                )
            }

            composable(Screen.ManualEventCode.route) {
                ManualEventCodeRoute(session, onBack = { navController.popBackStack() })
            }

            composable(Screen.HomeEventCode.route) {
                ManualEventCodeRoute(
                    session,
                    onBack = { navController.popBackStack() },
                    onJoined = { navController.popBackStack(Screen.Home.route, inclusive = false) },
                )
            }

            // Content only, like the other pushed record screens: no top bar, system Back.
            composable(Screen.RecordsByEvent.route) {
                RecordsByEventRoute(
                    proofRecordStore,
                    onOpenEventRecords = { navController.navigate(Screen.EventRecords.route(it)) },
                    sigilPresenceStore = sigilPresenceStore,
                )
            }

            composable(Screen.Records.route) {
                RecordsRoute(
                    proofRecordStore,
                    onOpenToday = { navController.navigate(Screen.TodaySummary.route) },
                    onOpenDetail = { recordId -> navController.navigate(Screen.RecordDetail.route(recordId)) },
                )
            }

            composable(Screen.TodaySummary.route) {
                TodaySummaryRoute(proofRecordStore)
            }

            composable(
                route = Screen.EventRecords.route,
                arguments = listOf(navArgument(Screen.EventRecords.ANCHOR_ID_ARG) { type = NavType.StringType }),
            ) { entry ->
                val anchorId = UUID.fromString(requireNotNull(entry.arguments?.getString(Screen.EventRecords.ANCHOR_ID_ARG)))
                RecordsRoute(
                    proofRecordStore,
                    onOpenToday = { navController.navigate(Screen.TodaySummary.route) },
                    onOpenDetail = { navController.navigate(Screen.RecordDetail.route(it)) },
                    eventGroupAnchorId = anchorId,
                    sigilPresenceStore = sigilPresenceStore,
                )
            }

            composable(
                route = Screen.RecordDetail.route,
                arguments = listOf(navArgument(Screen.RecordDetail.RECORD_ID_ARG) { type = NavType.StringType }),
            ) { backStackEntry ->
                val recordIdArg = requireNotNull(
                    backStackEntry.arguments?.getString(Screen.RecordDetail.RECORD_ID_ARG),
                )
                RecordDetailRoute(
                    proofRecordStore,
                    sessionAggregateSnapshotStore,
                    recordId = UUID.fromString(recordIdArg),
                    onRecordNotFound = { navController.popBackStack() },
                    sigilPresenceStore = sigilPresenceStore,
                )
            }
        }
    }
}

private fun bluetoothRouteScreenOf(route: String?): BluetoothRouteScreen? = when (route) {
    null -> null
    Screen.Welcome.route, Screen.BluetoothPermission.route -> BluetoothRouteScreen.Onboarding
    Screen.BluetoothDenied.route -> BluetoothRouteScreen.BluetoothDenied
    Screen.BluetoothOff.route -> BluetoothRouteScreen.BluetoothOff
    else -> BluetoothRouteScreen.App
}

private val BluetoothRouteTarget.route: String
    get() = when (this) {
        BluetoothRouteTarget.Home -> Screen.Home.route
        BluetoothRouteTarget.BluetoothOff -> Screen.BluetoothOff.route
        BluetoothRouteTarget.BluetoothDenied -> Screen.BluetoothDenied.route
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
 * BluetoothPermission → BluetoothOff → Home), and by the second hop
 * `Welcome` is no longer on the back stack at all, so a `popUpTo(Welcome)`
 * would silently no-op there and leave `BluetoothOff` stranded underneath
 * `Home`.
 */
private fun navigateClearingOnboarding(navController: NavHostController, route: String) {
    navController.navigate(route) {
        popUpTo(navController.graph.id) { inclusive = true }
    }
}
