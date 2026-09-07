package org.levarac.beid

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import org.levarac.beid.navigation.AppNavHost
import org.levarac.beid.persistence.ProofRecordStore
import org.levarac.beid.registry.RegistryDependencies
import org.levarac.beid.scenario.AndroidDataSource
import org.levarac.beid.scenario.AndroidScenarioAdvance
import org.levarac.beid.scenario.AndroidScenarioPlayback
import org.levarac.beid.scenario.AndroidScenarioSurface
import org.levarac.beid.scenario.playback
import org.levarac.beid.scenario.selectAndroidDataSource
import org.levarac.beid.sensing.EventJoinCoordinator
import org.levarac.beid.sensing.ProofRecordingBridge
import org.levarac.beid.ui.screens.EventJoinContent
import org.levarac.beid.ui.screens.RecordsScreen
import org.levarac.beid.ui.theme.BeidAppTheme
import org.levarac.parallax.registry.RegistryClient

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
    private var eventJoinCoordinator: EventJoinCoordinator? = null
    private var registryClient: RegistryClient? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        when (
            val dataSource = selectAndroidDataSource(
                requestedScenario = intent.getStringExtra(DEMO_SCENARIO_EXTRA),
                scenariosEnabled = BuildConfig.DEBUG,
                requestedSurface = intent.getStringExtra(DEMO_SCENARIO_SURFACE_EXTRA),
            )
        ) {
            AndroidDataSource.RealBle -> startRealBleApp()
            is AndroidDataSource.ReadOnlyScenario -> startReadOnlyScenario(dataSource)
        }
    }

    private fun startRealBleApp() {
        registryClient = RegistryDependencies.createClient()
        val coordinator = EventJoinCoordinator(this)
        eventJoinCoordinator = coordinator

        // Sibling store MainActivity owns directly (beid#121) — not something
        // EventJoinCoordinator owns, unlike SelfProofRecordStore/BindingRecordStore.
        val proofRecordStore = ProofRecordStore(ProofRecordStore.defaultFile(filesDir))
        val proofRecordingBridge = ProofRecordingBridge(proofRecordStore)
        wireProofRecording(coordinator, proofRecordingBridge)

        setContent {
            BeidAppTheme {
                AppNavHost(coordinator, proofRecordStore)
            }
        }
    }

    private fun startReadOnlyScenario(dataSource: AndroidDataSource.ReadOnlyScenario) {
        setContent {
            BeidAppTheme {
                ReadOnlyScenarioContent(dataSource.scenario.playback(), dataSource.surface)
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
        eventJoinCoordinator?.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun onDestroy() {
        registryClient?.close()
        eventJoinCoordinator?.dispose()
        super.onDestroy()
    }

    companion object {
        /** adb: `am start ... --es beid-demo-scenario crowdSurge` (Debug builds only). */
        const val DEMO_SCENARIO_EXTRA = "beid-demo-scenario"
        const val DEMO_SCENARIO_SURFACE_EXTRA = "beid-demo-surface"
    }
}

/** Local-only renderer. Its only state is a cursor over immutable screen models. */
@Composable
internal fun ReadOnlyScenarioContent(
    playback: AndroidScenarioPlayback,
    surface: AndroidScenarioSurface,
) {
    if (surface == AndroidScenarioSurface.Records) {
        RecordsScreen(playback.frames.last().snapshot.records)
        return
    }

    var frameIndex by remember(playback.scenario) { mutableIntStateOf(0) }
    val frame = playback.frames[frameIndex]
    LaunchedEffect(playback.scenario, frameIndex) {
        if (frame.advance == AndroidScenarioAdvance.Automatic) {
            kotlinx.coroutines.delay(SCENARIO_FRAME_DELAY_MILLIS)
            frameIndex += 1
        }
    }
    // The same stateless renderer production uses (beid#363). Every action
    // callback except frame advance is a no-op: a read-only scenario has no
    // session to join, no settings to open, and no way to reach recording,
    // signing, or submission.
    EventJoinContent(
        state = frame.snapshot.eventJoinScreenState,
        onOpenAccount = {},
        onJoinNearbyEvent = {},
        onOpenSettings = {},
        onSimulateSignalLost = {},
        onResumeSensing = {
            if (frame.advance == AndroidScenarioAdvance.Resume) frameIndex += 1
        },
    )
}

private const val SCENARIO_FRAME_DELAY_MILLIS = 700L

/**
 * Connects [EventJoinCoordinator]'s three proof-recording callback
 * properties (gh#235, `EventJoinCoordinator.kt`, landed in PR #321) to
 * [bridge] — the wiring beid#121 was blocked on until #235 landed. A
 * top-level function rather than inline in [MainActivity.onCreate] so it
 * has a seam testable independent of `Activity`/Robolectric construction:
 * [EventJoinCoordinator]'s `Activity`-based constructor pulls in a live
 * `BarnardEventJoinEngine`, Keystore-backed `BarnardSensingCryptography`,
 * and Bluetooth permission plumbing that this repository's existing tests
 * never construct through Robolectric (they use
 * [EventJoinCoordinator]'s `internal` test constructor with fakes
 * instead — see `EventJoinCoordinatorSelfProofTest`/
 * `EventJoinCoordinatorBindingTest` for the established pattern). This
 * function is that same testable seam: it takes an already-constructed
 * [EventJoinCoordinator] (real or fake-backed) and only asserts the
 * three-property assignment itself — see `MainActivityWiringTest` for the
 * coverage this seam provides and what it deliberately does not cover
 * (namely, `MainActivity.onCreate()`'s own construction of the real
 * `Activity`-backed [EventJoinCoordinator]/[ProofRecordStore]/[bridge]
 * instances, which stays unverified by a unit test in this repository's
 * current Robolectric setup).
 */
internal fun wireProofRecording(coordinator: EventJoinCoordinator, bridge: ProofRecordingBridge) {
    coordinator.onProofCollected = bridge::onProofCollected
    coordinator.onPeersVerifiedChanged = bridge::onPeersVerifiedChanged
    coordinator.onProofSignatureStateChanged = bridge::onProofSignatureStateChanged
}
