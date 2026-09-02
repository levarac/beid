package org.levarac.beid

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import org.levarac.beid.navigation.AppNavHost
import org.levarac.beid.persistence.ProofRecordStore
import org.levarac.beid.registry.RegistryDependencies
import org.levarac.beid.sensing.EventJoinCoordinator
import org.levarac.beid.sensing.ProofRecordingBridge
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
    private lateinit var eventJoinCoordinator: EventJoinCoordinator
    private var registryClient: RegistryClient? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        registryClient = RegistryDependencies.createClient()
        eventJoinCoordinator = EventJoinCoordinator(this)

        // Sibling store MainActivity owns directly (beid#121) — not something
        // EventJoinCoordinator owns, unlike SelfProofRecordStore/BindingRecordStore.
        val proofRecordStore = ProofRecordStore(ProofRecordStore.defaultFile(filesDir))
        val proofRecordingBridge = ProofRecordingBridge(proofRecordStore)
        // TODO(#235): once EventJoinCoordinator exposes onProofCollected/
        // onPeersVerifiedChanged/onProofSignatureStateChanged, wire them here:
        // eventJoinCoordinator.onProofCollected = proofRecordingBridge::onProofCollected
        // eventJoinCoordinator.onPeersVerifiedChanged = proofRecordingBridge::onPeersVerifiedChanged
        // eventJoinCoordinator.onProofSignatureStateChanged = proofRecordingBridge::onProofSignatureStateChanged

        setContent {
            BeidAppTheme {
                AppNavHost(eventJoinCoordinator, proofRecordStore)
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
        registryClient?.close()
        eventJoinCoordinator.dispose()
        super.onDestroy()
    }
}
