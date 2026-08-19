package org.levarac.beid.sensing

import org.levarac.beid.shared.sensing.ScanPhaseKind
import org.levarac.beid.shared.sensing.applyScanDetection
import org.levarac.beid.shared.sensing.scanPhaseAfterResumeSensing
import org.levarac.beid.shared.sensing.scanPhaseAfterSignalLost
import org.levarac.beid.shared.sensing.scanPhaseAfterStartSensing
import org.levarac.beid.shared.sensing.scanPhaseAfterStopSensing

/**
 * Native identity for the event a scan session is currently attached to.
 * Mirrors iOS's `EventSession` (`ios/Beid/Models/EventSession.swift`) at the
 * minimal shape this slice needs — see beid#120.
 */
data class ScanEventSession(val eventCode: String)

/**
 * Android-native mirror of iOS's `ScanPhase` (`ios/Beid/Sensing/ScanPhase.swift`).
 * The five cases and the rules for moving between them are owned by
 * `org.levarac.beid.shared.sensing` (beid#116; mirrored as [ScanPhaseKind]
 * there, without this type's native-owned [ScanEventSession]/`peersVerified`
 * payload) — see [applyPhaseDecision]/[applyStartSensing]/[applyStopSensing]/
 * [applySignalLost]/[applyResumeSensing], the sole call sites into shared.
 */
sealed class ScanPhase {
    data object Idle : ScanPhase()
    data object Sensing : ScanPhase()
    data class EventFound(val session: ScanEventSession) : ScanPhase()

    /**
     * [peersVerified] is a cumulative, no-denominator count of distinct
     * devices — mirrors iOS's `ScanPhase.recording(event:peersVerified:)`.
     * See [ScanDeviceAccounting] for how the underlying count is produced.
     */
    data class Recording(val session: ScanEventSession, val peersVerified: Int) : ScanPhase()

    /** Frozen count, resumable via [applyResumeSensing] — not a restart. */
    data class SignalLost(val session: ScanEventSession, val peersVerified: Int) : ScanPhase()
}

/**
 * [ScanPhase] mirroring the matching [ScanPhaseKind], without this type's
 * native-owned associated data — the conversion half of the adapter contract
 * for every call into `org.levarac.beid.shared.sensing`. Mirrors iOS's
 * `SensingCoordinator.currentPhaseKind`.
 */
fun ScanPhase.kind(): ScanPhaseKind = when (this) {
    ScanPhase.Idle -> ScanPhaseKind.IDLE
    ScanPhase.Sensing -> ScanPhaseKind.SENSING
    is ScanPhase.EventFound -> ScanPhaseKind.EVENT_FOUND
    is ScanPhase.Recording -> ScanPhaseKind.RECORDING
    is ScanPhase.SignalLost -> ScanPhaseKind.SIGNAL_LOST
}

/**
 * Calls the shared phase reducer ([applyScanDetection], beid#116) for
 * [currentPhase] with the given counts, and maps its result back onto
 * [ScanPhase] — the phase-decision half of the adapter, mirroring iOS's
 * `SensingCoordinator.applyPhaseDecision`. This function holds no threshold
 * or transition-graph logic of its own; every branch below only reads flags
 * [applyScanDetection] already computed.
 *
 * [session] is the native session to attach to a freshly transitioned
 * `EVENT_FOUND`/`RECORDING` phase (the caller resolves it — e.g. from
 * `BarnardEngine.getCurrentEventCode()` — before calling this, mirroring
 * iOS's `beginEventFoundSessionState`); it is not read at all when
 * [currentPhase] is `IDLE`/`SIGNAL_LOST`, since [applyScanDetection] always
 * reports those as no-ops.
 *
 * `result.confirmedEvent` is checked first, ahead of
 * `transitionedToEventFound`: when both are true (an `eventConfirmThreshold`
 * of `1` collapsing `SENSING` straight to `RECORDING` in one call — see
 * [applyScanDetection]'s own doc comment), [ScanPhase.EventFound] must never
 * be observed as an intermediate value.
 */
fun applyPhaseDecision(
    currentPhase: ScanPhase,
    session: ScanEventSession,
    coPresentDeviceCount: Int,
    distinctDeviceCount: Int,
    distinctDeviceCountChanged: Boolean,
    eventConfirmThreshold: Int,
): ScanPhase {
    val result = applyScanDetection(
        currentPhase = currentPhase.kind(),
        coPresentDeviceCount = coPresentDeviceCount,
        distinctDeviceCount = distinctDeviceCount,
        distinctDeviceCountChanged = distinctDeviceCountChanged,
        eventConfirmThreshold = eventConfirmThreshold,
    )

    return when {
        result.confirmedEvent -> ScanPhase.Recording(session = session, peersVerified = distinctDeviceCount)
        result.transitionedToEventFound -> ScanPhase.EventFound(session = session)
        result.updatedRecording && currentPhase is ScanPhase.Recording ->
            currentPhase.copy(peersVerified = distinctDeviceCount)
        else -> currentPhase
    }
}

/** `IDLE -> SENSING`, unconditional — mirrors iOS's `startSensing(eventCode:)`. */
fun applyStartSensing(): ScanPhase {
    check(scanPhaseAfterStartSensing() == ScanPhaseKind.SENSING)
    return ScanPhase.Sensing
}

/** Any phase `-> IDLE`, unconditional — mirrors iOS's `endSensing(stopEngine:)`. */
fun applyStopSensing(): ScanPhase {
    check(scanPhaseAfterStopSensing() == ScanPhaseKind.IDLE)
    return ScanPhase.Idle
}

/**
 * `RECORDING -> SIGNAL_LOST`, freezing the recorded count. A no-op from any
 * other phase — mirrors iOS's `simulateSignalLost()`.
 * [scanPhaseAfterSignalLost] is the sole authority on whether this applies;
 * this function only extracts the payload it has already confirmed is
 * there, it does not re-decide.
 */
fun applySignalLost(currentPhase: ScanPhase): ScanPhase {
    val result = scanPhaseAfterSignalLost(currentPhase.kind())
    if (!result.applied) return currentPhase
    return when (currentPhase) {
        is ScanPhase.Recording -> ScanPhase.SignalLost(currentPhase.session, currentPhase.peersVerified)
        else -> currentPhase
    }
}

/**
 * `SIGNAL_LOST -> RECORDING`, resuming in place — never a restart, so
 * nothing already recorded is discarded. Mirrors iOS's `resumeSensing()`.
 * [scanPhaseAfterResumeSensing] is the sole authority on whether this
 * applies.
 */
fun applyResumeSensing(currentPhase: ScanPhase): ScanPhase {
    val result = scanPhaseAfterResumeSensing(currentPhase.kind())
    if (!result.applied) return currentPhase
    return when (currentPhase) {
        is ScanPhase.SignalLost -> ScanPhase.Recording(currentPhase.session, currentPhase.peersVerified)
        else -> currentPhase
    }
}
