package org.levarac.beid.navigation

import android.app.Application
import android.bluetooth.BluetoothAdapter
import android.content.Context
import android.content.Intent
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.assertContentDescriptionEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.core.app.ApplicationProvider
import java.io.File
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.levarac.beid.R
import org.levarac.beid.onboarding.OnboardingPreferences
import org.levarac.beid.persistence.BindingRecordStore
import org.levarac.beid.persistence.ProofRecordStore
import org.levarac.beid.persistence.SelfProofRecordStore
import org.levarac.beid.sensing.BluetoothPermissionState
import org.levarac.beid.sensing.EventJoinCoordinator
import org.levarac.beid.sensing.FakeEventJoinEngine
import org.levarac.beid.sensing.FakeSensingCryptography
import org.levarac.beid.ui.screens.AccountScreenTestTags
import org.levarac.beid.ui.screens.HomeScreenTestTags
import org.levarac.beid.ui.screens.NowScreenTestTags
import org.levarac.beid.ui.screens.RecordsHomeScreenTestTags
import org.levarac.beid.ui.theme.BeidAppTheme
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper

/**
 * The Now tab follows the live radio through the production graph: the real
 * `AppNavHost`, its `BluetoothStateMonitor` (driven by the radio broadcast),
 * the standby gate and a real [EventJoinCoordinator] over a fake engine, so
 * scan starts and stops are counted where they reach the radio.
 *
 * The invariant (iOS integration/ios-1.1.1 `AppCoordinator.updateHomeStandby`
 * plus `SensingCoordinator.stopNearbyEventDiscovery` clearing
 * `homeStandbyDiscoveryRequested`): standby discovery runs if and only if the
 * gate is open and the radio is on.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class HomeBluetoothRadioTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    @get:Rule val folder = TemporaryFolder()

    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private val adapter get() = shadowOf(BluetoothAdapter.getDefaultAdapter())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val engine = FakeEventJoinEngine()
    private lateinit var coordinator: EventJoinCoordinator

    @Before fun prepare() {
        OnboardingPreferences(context).hasCompletedOnboarding = true
        adapter.setEnabled(true)
        coordinator = EventJoinCoordinator(
            engine = engine,
            nowEpochMillis = System::currentTimeMillis,
            coroutineScope = scope,
            sensingCryptography = FakeSensingCryptography(),
            selfProofRecordStore = SelfProofRecordStore(File(folder.root, "self-proofs.json")),
            bindingRecordStore = BindingRecordStore(File(folder.root, "bindings.json")),
            initialBluetoothPermissionState = BluetoothPermissionState.Granted,
        )
        val store = ProofRecordStore(File(folder.root, "records.json"))
        compose.setContent { BeidAppTheme { AppNavHost(coordinator, store) } }
        compose.onNodeWithTag(NowScreenTestTags.ROOT).assertIsDisplayed()
        assertEquals(1, engine.startScanCalls, "Now starts standby discovery once on launch")
    }

    @After fun tearDown() = scope.cancel()

    private fun radio(on: Boolean) {
        adapter.setEnabled(on)
        context.sendBroadcast(
            Intent(BluetoothAdapter.ACTION_STATE_CHANGED)
                .putExtra(BluetoothAdapter.EXTRA_STATE, if (on) BluetoothAdapter.STATE_ON else BluetoothAdapter.STATE_OFF),
        )
        ShadowLooper.idleMainLooper()
        compose.waitForIdle()
    }

    private fun bluetoothOffBlock() = compose.onNodeWithTag(NowScreenTestTags.BLUETOOTH_OFF)

    @Test fun aRadioToggleWhileNowStaysResumedStopsThenResumesDiscoveryExactlyOnce() {
        bluetoothOffBlock().assertDoesNotExist()

        radio(on = false)

        bluetoothOffBlock().performScrollTo().assertIsDisplayed()
        compose.onNodeWithTag(NowScreenTestTags.LISTENING).assertDoesNotExist()
        assertEquals(1, engine.stopScanCalls, "radio off stops the standby scan once")
        assertFalse(engine.engineState.isScanning)
        assertEquals(1, engine.startScanCalls, "nothing restarts while the radio is off")

        radio(on = true)

        bluetoothOffBlock().assertDoesNotExist()
        compose.onNodeWithTag(NowScreenTestTags.LISTENING).assertIsDisplayed()
        assertEquals(2, engine.startScanCalls, "radio on resumes the standby scan exactly once")
        assertEquals(1, engine.stopScanCalls)
        assertTrue(engine.engineState.isScanning)
    }

    @Test fun radioBackWhileOnRecordsStartsNothingAndNowStartsItOnce() {
        radio(on = false)
        compose.onNodeWithTag(HomeScreenTestTags.RECORDS_TAB).performClick()
        compose.onNodeWithTag(RecordsHomeScreenTestTags.ROOT).assertIsDisplayed()

        radio(on = true)

        assertEquals(1, engine.startScanCalls, "radio back on Records starts nothing")
        assertFalse(engine.engineState.isScanning)

        compose.onNodeWithTag(HomeScreenTestTags.NOW_TAB).performClick()
        compose.onNodeWithTag(NowScreenTestTags.LISTENING).assertIsDisplayed()
        assertEquals(2, engine.startScanCalls, "returning to Now starts it once")
        assertTrue(engine.engineState.isScanning)
    }

    @Test fun radioBackWhileOnAccountStartsNothingAndNowStartsItOnce() {
        radio(on = false)
        compose.onNodeWithContentDescription(context.getString(R.string.home_account_title)).performClick()
        compose.onNodeWithTag(AccountScreenTestTags.RECORDS_BUTTON).assertIsDisplayed()

        radio(on = true)

        assertEquals(1, engine.startScanCalls, "radio back on Account starts nothing")
        assertFalse(engine.engineState.isScanning)

        compose.runOnUiThread { compose.activity.onBackPressedDispatcher.onBackPressed() }
        compose.onNodeWithTag(NowScreenTestTags.LISTENING).assertIsDisplayed()
        assertEquals(2, engine.startScanCalls, "returning to Now starts it once")
    }

    @Test fun fixSwitchesToTheBluetoothOffScreen() {
        radio(on = false)
        compose.onNodeWithTag(NowScreenTestTags.BLUETOOTH_FIX).performScrollTo()
            .assertContentDescriptionEquals(context.getString(R.string.now_bluetooth_fix_accessibility))
            .performClick()

        compose.onNodeWithTag("bluetooth_off_turned_on_button").assertIsDisplayed()
        compose.onNodeWithTag(HomeScreenTestTags.ROOT).assertDoesNotExist()
    }

    @Test fun openSettingsStartsTheSystemBluetoothSettings() {
        radio(on = false)
        compose.onNodeWithTag(NowScreenTestTags.BLUETOOTH_OPEN_SETTINGS).performScrollTo()
            .assertContentDescriptionEquals(context.getString(R.string.now_open_settings_accessibility))
            .performClick()

        val started = shadowOf(ApplicationProvider.getApplicationContext<Application>()).nextStartedActivity
            ?: shadowOf(compose.activity).nextStartedActivity
        assertEquals(Settings.ACTION_BLUETOOTH_SETTINGS, started?.action)
    }

    @Test fun radioOffWhileOnRecordsKeepsNowClosedUntilTheRadioReturns() {
        compose.onNodeWithTag(HomeScreenTestTags.RECORDS_TAB).performClick()
        compose.onNodeWithTag(RecordsHomeScreenTestTags.ROOT).assertIsDisplayed()
        assertEquals(1, engine.stopScanCalls, "leaving Now stops discovery")
        radio(on = false)

        compose.onNodeWithTag(HomeScreenTestTags.NOW_TAB).performClick()

        bluetoothOffBlock().performScrollTo().assertIsDisplayed()
        assertEquals(1, engine.startScanCalls, "Now with the radio off starts nothing")

        radio(on = true)

        assertEquals(2, engine.startScanCalls)
        assertEquals(1, engine.stopScanCalls)
    }
}
