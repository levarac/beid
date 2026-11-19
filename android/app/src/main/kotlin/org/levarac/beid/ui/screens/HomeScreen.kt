package org.levarac.beid.ui.screens

import android.os.SystemClock
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.viewmodel.compose.viewModel
import java.util.UUID
import org.levarac.beid.BuildConfig
import org.levarac.beid.R
import org.levarac.beid.navigation.HomeStandbyViewModel
import org.levarac.beid.navigation.HomeTab
import org.levarac.beid.persistence.ProofRecordStore
import org.levarac.beid.sensing.ClockPreflightController
import org.levarac.beid.sensing.EventJoinSession
import org.levarac.beid.sensing.EventJoinUiState
import org.levarac.beid.sensing.OperatorDateHeaderSource
import org.levarac.beid.sensing.operatorOriginOrNull
import org.levarac.beid.ui.theme.BeidTheme

/** Compose test tags for the Home shell; not user-facing copy. */
object HomeScreenTestTags {
    /** The shell itself, present on both tabs. */
    const val ROOT = "collection_home"
    const val NOW_TAB = "home_tab_now"
    const val RECORDS_TAB = "home_tab_records"
}

/**
 * Home after iOS #795 (`CollectionHomeView`): two tabs, Now and Records, with
 * Account in the top bar on both.
 *
 * Owns the one [EventJoinViewModel] the Now body renders and the
 * [HomeStandbyViewModel] that decides when nearby discovery runs. Both are
 * scoped to the Home back-stack entry, whose lifecycle is RESUMED only while
 * Home is the top destination of a resumed Activity — that one signal is the
 * gate's "visible and active" input, so pushing Account, event-code entry or a
 * record over Home, or backgrounding the app, stops discovery and resets the
 * 30-second wait.
 *
 * [isBluetoothOff] is the Bluetooth-off binding point: it is read on
 * composition and on every lifecycle event of the Home entry (so returning from
 * system settings re-reads it) and feeds both the inline Bluetooth-off block
 * and the standby gate. Production passes a read of `BluetoothRadioMonitor`;
 * an observable radio state can replace the provider without touching Now.
 */
@Composable
fun HomeRoute(
    session: EventJoinSession,
    proofRecordStore: ProofRecordStore,
    onOpenAccount: () -> Unit,
    onOpenEventCodeEntry: () -> Unit,
    onOpenRecord: (UUID) -> Unit,
    onOpenToday: () -> Unit,
    onOpenByEvent: () -> Unit,
    onFixBluetooth: () -> Unit,
    onOpenBluetoothSettings: () -> Unit,
    isBluetoothOff: () -> Boolean,
    onStartWalletBinding: () -> Unit = {},
    /** beid#464. Injectable so tests can pass a fake date source; production uses the default. */
    clockPreflight: ClockPreflightController = remember {
        ClockPreflightController(
            OperatorDateHeaderSource(operatorOriginOrNull(BuildConfig.EVENT_CODE_LOOKUP_URL_TEMPLATE)),
        )
    },
    standbyUptimeMillis: () -> Long = SystemClock::uptimeMillis,
    showSimulateSignalLost: Boolean = BuildConfig.DEBUG,
) {
    val viewModel: EventJoinViewModel = viewModel(factory = EventJoinViewModel.Factory(session, clockPreflight))
    val standbyViewModel: HomeStandbyViewModel =
        viewModel(factory = HomeStandbyViewModel.Factory(session, standbyUptimeMillis))
    val uiState by viewModel.uiState.collectAsState()
    val standby by standbyViewModel.presentation.collectAsState()

    var selectedTab by rememberSaveable { mutableStateOf(HomeTab.Now) }
    var bluetoothOff by remember { mutableStateOf(isBluetoothOff()) }
    val currentIsBluetoothOff by rememberUpdatedState(isBluetoothOff)
    LaunchedEffect(selectedTab) { standbyViewModel.onTabSelected(selectedTab) }
    LaunchedEffect(bluetoothOff) { standbyViewModel.onBluetoothOffChanged(bluetoothOff) }

    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner, standbyViewModel) {
        val lifecycle = lifecycleOwner.lifecycle
        val observer = LifecycleEventObserver { _, _ ->
            bluetoothOff = currentIsBluetoothOff()
            standbyViewModel.onRootResumedChanged(lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))
        }
        lifecycle.addObserver(observer)
        onDispose {
            lifecycle.removeObserver(observer)
            standbyViewModel.onRootResumedChanged(false)
        }
    }

    HomeContent(
        selectedTab = selectedTab,
        onSelectTab = { selectedTab = it },
        isSensing = uiState.sessionState is EventJoinUiState.Sensing,
        onOpenAccount = onOpenAccount,
        onCloseScan = viewModel::requestScanClose,
        nowContent = { contentModifier ->
            NowContent(
                state = uiState,
                standby = standby,
                bluetoothOff = bluetoothOff,
                onJoinNearbyEvent = viewModel::joinNearbyEvent,
                onOpenCodeEntry = onOpenEventCodeEntry,
                onFixBluetooth = onFixBluetooth,
                onOpenBluetoothSettings = onOpenBluetoothSettings,
                onOpenSettings = viewModel::openAppSettings,
                onSimulateSignalLost = viewModel::simulateSignalLost,
                onResumeSensing = viewModel::resumeSensing,
                onStartWalletBinding = onStartWalletBinding,
                onRetryClockPreflight = viewModel::retryClockPreflight,
                showEntranceCeremony = !uiState.recordingCeremonyShown,
                onCeremonyFinished = viewModel::markRecordingCeremonyShown,
                showSimulateSignalLost = showSimulateSignalLost,
                onKeepSensing = viewModel::keepSensing,
                onConfirmStopSensing = viewModel::confirmStopSensing,
                modifier = contentModifier,
            )
        },
        recordsContent = { contentModifier ->
            RecordsHomeRoute(
                proofRecordStore = proofRecordStore,
                onOpenRecord = onOpenRecord,
                onOpenToday = onOpenToday,
                onOpenByEvent = onOpenByEvent,
                modifier = contentModifier,
            )
        },
    )
}

/**
 * The stateless shell: an OS-standard top bar holding Account (and Close while
 * a session is sensing on Now), and the Material 3 navigation bar standing in
 * for iOS's `TabView` (DESIGN.md, 1.1 screen specification: the Now / Records
 * tab bar is an OS-standard control with system symbols and titles). Colors
 * come from [BeidTheme] roles; the tab labels keep the system font.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeContent(
    selectedTab: HomeTab,
    onSelectTab: (HomeTab) -> Unit,
    isSensing: Boolean,
    onOpenAccount: () -> Unit,
    onCloseScan: () -> Unit,
    nowContent: @Composable (Modifier) -> Unit,
    recordsContent: @Composable (Modifier) -> Unit,
) {
    val colors = BeidTheme.colors
    Scaffold(
        modifier = Modifier.testTag(HomeScreenTestTags.ROOT),
        containerColor = colors.surfaceCanvas,
        topBar = {
            TopAppBar(
                title = {},
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = colors.surfaceCanvas,
                    actionIconContentColor = colors.textPrimary,
                ),
                actions = {
                    if (selectedTab == HomeTab.Now && isSensing) {
                        TextButton(onClick = onCloseScan) {
                            Text(text = stringResource(R.string.scan_close), color = colors.textPrimary)
                        }
                    }
                    IconButton(
                        onClick = onOpenAccount,
                        modifier = Modifier.testTag(EventJoinScreenTestTags.ACCOUNT_ENTRY),
                    ) {
                        Icon(
                            imageVector = Icons.Filled.AccountCircle,
                            contentDescription = stringResource(R.string.home_account_title),
                        )
                    }
                },
            )
        },
        bottomBar = {
            NavigationBar(containerColor = colors.surfaceCanvas, contentColor = colors.textPrimary) {
                HomeTabItem(
                    selected = selectedTab == HomeTab.Now,
                    onClick = { onSelectTab(HomeTab.Now) },
                    icon = Icons.Filled.Sensors,
                    label = stringResource(R.string.home_now_title),
                    testTag = HomeScreenTestTags.NOW_TAB,
                )
                HomeTabItem(
                    selected = selectedTab == HomeTab.Records,
                    onClick = { onSelectTab(HomeTab.Records) },
                    icon = Icons.Filled.GridView,
                    label = stringResource(R.string.records_title),
                    testTag = HomeScreenTestTags.RECORDS_TAB,
                )
            }
        },
    ) { innerPadding ->
        val contentModifier = Modifier.padding(innerPadding).consumeWindowInsets(innerPadding)
        when (selectedTab) {
            HomeTab.Now -> nowContent(contentModifier)
            HomeTab.Records -> recordsContent(contentModifier)
        }
    }
}

@Composable
private fun RowScope.HomeTabItem(
    selected: Boolean,
    onClick: () -> Unit,
    icon: ImageVector,
    label: String,
    testTag: String,
) {
    val colors = BeidTheme.colors
    NavigationBarItem(
        selected = selected,
        onClick = onClick,
        // The label names the tab; the symbol is decorative, as iOS `Label` reads its title.
        icon = { Icon(imageVector = icon, contentDescription = null) },
        label = {
            Text(
                text = label,
                style = MaterialTheme.typography.labelMedium.copy(fontFamily = FontFamily.Default),
            )
        },
        colors = NavigationBarItemDefaults.colors(
            selectedIconColor = colors.textPrimary,
            selectedTextColor = colors.textPrimary,
            indicatorColor = colors.surfaceTile,
            unselectedIconColor = colors.textSecondary,
            unselectedTextColor = colors.textSecondary,
        ),
        modifier = Modifier.testTag(testTag),
    )
}
