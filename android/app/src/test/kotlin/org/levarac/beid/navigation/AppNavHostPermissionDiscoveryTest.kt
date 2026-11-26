package org.levarac.beid.navigation

import android.bluetooth.BluetoothAdapter
import android.content.Context
import android.content.Intent
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
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
import org.levarac.beid.onboarding.OnboardingPreferences
import org.levarac.beid.persistence.BindingRecordStore
import org.levarac.beid.persistence.ProofRecordStore
import org.levarac.beid.persistence.SelfProofRecordStore
import org.levarac.beid.sensing.BluetoothPermissionState
import org.levarac.beid.sensing.EventJoinCoordinator
import org.levarac.beid.sensing.FakeEventJoinEngine
import org.levarac.beid.sensing.FakeSensingCryptography
import org.levarac.beid.ui.screens.BluetoothDeniedScreenTestTags
import org.levarac.beid.ui.screens.BluetoothOffScreenTestTags
import org.levarac.beid.ui.screens.BluetoothPermissionScreenTestTags
import org.levarac.beid.ui.screens.NowScreenTestTags
import org.levarac.beid.ui.screens.WelcomeScreenTestTags
import org.levarac.beid.ui.theme.BeidAppTheme
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper

/**
 * Onboarding's permission grant routes the user; only the Now standby gate
 * starts discovery. Runs the real `AppNavHost` over a real
 * [EventJoinCoordinator] and a fake engine, so scan starts are counted where
 * they reach the radio.
 *
 * iOS release/1.1.0: `AppCoordinator.requestBluetoothPermission` ends in
 * `applyBluetoothState`, which only sets `screen`; discovery starts from
 * `updateHomeStandby` → `startHomeStandbyDiscovery` once Home is visible.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class AppNavHostPermissionDiscoveryTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    @get:Rule val folder = TemporaryFolder()

    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private val adapter get() = shadowOf(BluetoothAdapter.getDefaultAdapter())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val engine = FakeEventJoinEngine()

    @Before fun prepare() {
        OnboardingPreferences(context).hasCompletedOnboarding = false
    }

    @After fun tearDown() = scope.cancel()

    private fun launch(permission: BluetoothPermissionState = BluetoothPermissionState.NotDetermined) {
        val coordinator = EventJoinCoordinator(
            engine = engine,
            nowEpochMillis = System::currentTimeMillis,
            coroutineScope = scope,
            sensingCryptography = FakeSensingCryptography(),
            selfProofRecordStore = SelfProofRecordStore(File(folder.root, "self-proofs.json")),
            bindingRecordStore = BindingRecordStore(File(folder.root, "bindings.json")),
            initialBluetoothPermissionState = permission,
        )
        val store = ProofRecordStore(File(folder.root, "records.json"))
        compose.setContent { BeidAppTheme { AppNavHost(coordinator, store) } }
    }

    private fun radio(on: Boolean) {
        adapter.setEnabled(on)
        context.sendBroadcast(
            Intent(BluetoothAdapter.ACTION_STATE_CHANGED)
                .putExtra(BluetoothAdapter.EXTRA_STATE, if (on) BluetoothAdapter.STATE_ON else BluetoothAdapter.STATE_OFF),
        )
        ShadowLooper.idleMainLooper()
        compose.waitForIdle()
    }

    private fun allowBluetooth() {
        compose.onNodeWithTag(WelcomeScreenTestTags.GET_STARTED_BUTTON).performClick()
        compose.onNodeWithTag(BluetoothPermissionScreenTestTags.ALLOW_BUTTON).performClick()
        compose.waitForIdle()
    }

    @Test fun grantedWithTheRadioOffStartsNothingUntilNowIsShown() {
        adapter.setEnabled(false)
        launch()

        allowBluetooth()

        compose.onNodeWithTag(BluetoothOffScreenTestTags.TURNED_ON_BUTTON).assertIsDisplayed()
        assertEquals(0, engine.startScanCalls, "the grant routes to the Bluetooth-off guidance and starts nothing")

        radio(on = true)

        compose.onNodeWithTag(BluetoothOffScreenTestTags.TURNED_ON_BUTTON).assertIsDisplayed()
        assertEquals(0, engine.startScanCalls, "the radio returning behind the guidance starts nothing")
        assertFalse(engine.engineState.isScanning)

        compose.onNodeWithTag(BluetoothOffScreenTestTags.TURNED_ON_BUTTON).performClick()

        compose.onNodeWithTag(NowScreenTestTags.LISTENING).assertIsDisplayed()
        assertEquals(1, engine.startScanCalls, "Now's gate starts standby discovery once")
        assertTrue(engine.engineState.isScanning)
    }

    @Test fun grantedWithTheRadioOnReachesDiscoveryThroughNowOnce() {
        adapter.setEnabled(true)
        launch()

        allowBluetooth()

        compose.onNodeWithTag(NowScreenTestTags.LISTENING).assertIsDisplayed()
        assertEquals(1, engine.startScanCalls, "Now's gate starts standby discovery once")
        assertTrue(engine.engineState.isScanning)
    }

    @Test fun grantedFromTheDeniedGuidanceReachesDiscoveryThroughNowOnce() {
        OnboardingPreferences(context).hasCompletedOnboarding = true
        adapter.setEnabled(true)
        launch(BluetoothPermissionState.Denied)
        compose.onNodeWithTag(BluetoothDeniedScreenTestTags.CHECK_AGAIN_BUTTON).assertIsDisplayed()
        assertEquals(0, engine.startScanCalls)

        compose.onNodeWithTag(BluetoothDeniedScreenTestTags.CHECK_AGAIN_BUTTON).performClick()
        compose.waitForIdle()

        compose.onNodeWithTag(NowScreenTestTags.LISTENING).assertIsDisplayed()
        assertEquals(1, engine.startScanCalls, "Now's gate starts standby discovery once")
        assertTrue(engine.engineState.isScanning)
    }
}
