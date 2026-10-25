package org.levarac.beid.sensing

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import org.levarac.beid.persistence.ProofRecordStore
import org.levarac.beid.wireProofRecording

/**
 * The Activity's single session owner: retained across recreation, cleared on finish.
 * Only Application-backed dependencies live here; the current permission host and
 * wallet UI are attached by MainActivity and released when that host is destroyed.
 * Process death continues to use the durable checkpoint recovery path.
 */
class EventJoinSessionViewModel(application: Application) : AndroidViewModel(application) {
    val coordinator = EventJoinCoordinator(application)
    val proofRecordStore = ProcessSessionCheckpointRuntimeOwner.proofRecordStore(
        ProofRecordStore.defaultFile(application.filesDir),
    )

    init {
        wireProofRecording(coordinator, ProofRecordingBridge(proofRecordStore))
    }

    override fun onCleared() {
        coordinator.dispose()
    }
}
