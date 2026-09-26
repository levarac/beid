package org.levarac.beid.support

import androidx.lifecycle.ViewModel
import org.levarac.beid.BuildConfig
import org.levarac.beid.sensing.EventJoinUiState
import org.levarac.beid.sensing.ScanPhase
import org.levarac.beid.shared.event.eventJoinFailureReasonKey
import org.levarac.beid.shared.support.SupportBundleRecorder
import org.levarac.beid.shared.support.SupportFailure
import org.levarac.beid.shared.support.SupportPlatform
import org.levarac.beid.shared.support.SupportState
import org.levarac.beid.shared.support.supportFailureForReasonKey

/** Main-thread UI projection adapter. Event payloads are never inspected. */
class SupportDiagnostics(private val clock: () -> Long = System::currentTimeMillis) : ViewModel() {
    internal val recorder = SupportBundleRecorder()

    fun accept(state: EventJoinUiState) {
        val diagnostic = when (state) {
            EventJoinUiState.Idle -> SupportState.IDLE to SupportFailure.NONE
            EventJoinUiState.RequestingPermission -> SupportState.REQUESTING_PERMISSION to SupportFailure.NONE
            EventJoinUiState.VerifyingRegistry -> SupportState.VERIFYING_REGISTRY to SupportFailure.NONE
            EventJoinUiState.PermissionDenied -> SupportState.PERMISSION_DENIED to SupportFailure.PERMISSION_DENIED
            is EventJoinUiState.OwnerKeyUnavailable -> SupportState.OWNER_KEY_UNAVAILABLE to SupportFailure.OWNER_KEY_UNAVAILABLE
            is EventJoinUiState.JoinFailed -> SupportState.JOIN_FAILED to
                supportFailureForReasonKey(eventJoinFailureReasonKey(state.reason))
            is EventJoinUiState.Sensing -> when (state.phase) {
                ScanPhase.Idle -> SupportState.IDLE to SupportFailure.NONE
                ScanPhase.Sensing -> SupportState.SENSING to SupportFailure.NONE
                is ScanPhase.EventFound -> SupportState.EVENT_FOUND to SupportFailure.NONE
                is ScanPhase.Recording -> SupportState.RECORDING to SupportFailure.NONE
                is ScanPhase.SignalLost -> SupportState.SIGNAL_LOST to SupportFailure.SIGNAL_LOST
            }
        }
        recorder.record(diagnostic.first, diagnostic.second, clock())
    }

    fun exportJson(): String = recorder.exportJson(
        SupportPlatform.ANDROID,
        BuildConfig.VERSION_NAME,
        BuildConfig.VERSION_CODE.toString(),
    )
}
