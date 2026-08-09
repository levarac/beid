package org.levarac.beid.shared.sensing

/**
 * The shared scan-phase state machine — beid#116.
 *
 * Mirrors iOS's shipped `ScanPhase` (`ios/Beid/Sensing/ScanPhase.swift`),
 * which is this family's oracle: class B/CONVERGE, since Android has no
 * phase concept today (`EventJoinCoordinator.kt`'s `EventJoinUiState` stops
 * at `Idle`/`RequestingPermission`/`Sensing`/`PermissionDenied`). This
 * issue unifies the current criteria; it does not change them — the
 * unconditional first-detection `.sensing -> .eventFound` trigger is
 * intentionally not threshold-gated here, and changing that is beid#114's
 * job, not this one's.
 *
 * This enum intentionally carries none of `ScanPhase`'s associated data
 * (`EventSession`, `peersVerified`). Those are native identity/display
 * concerns: `shared` decides only which of the five phases the app is in
 * and when it moves between them, and native pairs that answer with the
 * session object and counters it already owns.
 */
public enum class ScanPhaseKind {
    IDLE,
    SENSING,
    EVENT_FOUND,
    RECORDING,
    SIGNAL_LOST,
}

/**
 * Enough devices present **at the same time** to confirm an event —
 * distinct proximity identifiers observed in the current ENIN window.
 *
 * Mirrors iOS's `hasEnoughCoPresentDevicesToConfirm`
 * (`SensingCoordinator.swift`). The caller clears [coPresentDeviceCount] at
 * every window boundary, so this arm never accumulates with dwell time — a
 * lingering device contributes exactly 1 to every window, forever.
 */
public fun hasEnoughCoPresentDevicesToConfirmScanEvent(
    coPresentDeviceCount: Int,
    eventConfirmThreshold: Int,
): Boolean = coPresentDeviceCount >= eventConfirmThreshold

/**
 * Enough distinct devices **at any point this session** to confirm an
 * event — a cumulative, non-rotating device count.
 *
 * Mirrors iOS's `hasEnoughDistinctDevicesToConfirm`. The caller keys
 * [distinctDeviceCount] on a stable per-event device identity (not the
 * rotating proximity identifier), so this arm also never accumulates with
 * dwell time on its own — one lingering device stays 1, however many
 * windows it is seen in.
 */
public fun hasEnoughDistinctDevicesToConfirmScanEvent(
    distinctDeviceCount: Int,
    eventConfirmThreshold: Int,
): Boolean = distinctDeviceCount >= eventConfirmThreshold

/**
 * Whether to confirm the event and start recording — either arm suffices.
 *
 * Mirrors iOS's `shouldConfirmEvent`. Both arms individually resist
 * accumulation (see their own doc comments), which is what makes a single
 * lingering device satisfy neither — the invariant iOS's
 * `testOneLingeringDeviceNeverSatisfiesTheConfirmThresholdOnItsOwn`
 * protects, and this family's own
 * `oneLingeringDeviceNeverSatisfiesEitherArmNoMatterHowManyWindowsPass`
 * vector must keep protecting after any edit here.
 */
public fun shouldConfirmScanEvent(
    coPresentDeviceCount: Int,
    distinctDeviceCount: Int,
    eventConfirmThreshold: Int,
): Boolean =
    hasEnoughCoPresentDevicesToConfirmScanEvent(coPresentDeviceCount, eventConfirmThreshold) ||
        hasEnoughDistinctDevicesToConfirmScanEvent(distinctDeviceCount, eventConfirmThreshold)

/**
 * The result of folding one detection into the phase machine.
 *
 * [resultingPhase] is the authoritative next phase; the three flags tell
 * the native caller which side effect to run. The same detection can
 * legitimately cause two phase moves in one call: an unconditional
 * `SENSING -> EVENT_FOUND` immediately followed by threshold-confirm into
 * `RECORDING`, when the very first detection already meets the threshold
 * (reachable today only via the DEBUG `-beid-threshold-override 1` launch
 * argument) — in that case both [transitionedToEventFound] and
 * [confirmedEvent] are true and [resultingPhase] is `RECORDING`.
 */
public class ScanDetectionResult internal constructor(
    public val resultingPhase: ScanPhaseKind,
    public val transitionedToEventFound: Boolean,
    public val confirmedEvent: Boolean,
    public val updatedRecording: Boolean,
)

/**
 * Folds one detection into the phase machine.
 *
 * [currentPhase] is the phase before this detection. [coPresentDeviceCount]
 * and [distinctDeviceCount] are plain counts the caller has already updated
 * for this detection — their source (Set-backed dedup, shared aggregation,
 * or otherwise) is a native/`aggregation`-family concern this reducer does
 * not own or inspect (beid#162 moves that source; this reducer only ever
 * sees its output as opaque `Int`s). [distinctDeviceCountChanged] is
 * whether this detection moved [distinctDeviceCount], which is what gates
 * a `RECORDING` update — a co-presence-only change does not, by itself,
 * republish the displayed count.
 *
 * Behavior by [currentPhase]:
 * - `IDLE`, `SIGNAL_LOST`: the detection is ignored — `resultingPhase`
 *   equals [currentPhase] and every flag is false, regardless of how large
 *   the supplied counts are. Resuming from `SIGNAL_LOST` is only ever the
 *   explicit [scanPhaseAfterResumeSensing] action, never automatic on the
 *   next detection.
 * - `SENSING`: unconditionally moves to `EVENT_FOUND` — no threshold, by
 *   design (beid#114 owns changing this, not this family). The same
 *   detection's counts are then also evaluated against the confirm
 *   threshold, so a threshold of 1 can carry straight through to
 *   `RECORDING` in one call.
 * - `EVENT_FOUND`: moves to `RECORDING` when [shouldConfirmScanEvent] is
 *   true for the supplied counts; otherwise stays `EVENT_FOUND`.
 * - `RECORDING`: stays `RECORDING`. [updatedRecording] is set exactly when
 *   [distinctDeviceCountChanged] — crossing the confirm threshold again in
 *   a later window is not new information, so [confirmedEvent] is always
 *   false here.
 */
public fun applyScanDetection(
    currentPhase: ScanPhaseKind,
    coPresentDeviceCount: Int,
    distinctDeviceCount: Int,
    distinctDeviceCountChanged: Boolean,
    eventConfirmThreshold: Int,
): ScanDetectionResult {
    val confirmed = shouldConfirmScanEvent(coPresentDeviceCount, distinctDeviceCount, eventConfirmThreshold)

    return when (currentPhase) {
        ScanPhaseKind.IDLE, ScanPhaseKind.SIGNAL_LOST ->
            ScanDetectionResult(
                resultingPhase = currentPhase,
                transitionedToEventFound = false,
                confirmedEvent = false,
                updatedRecording = false,
            )

        ScanPhaseKind.SENSING ->
            ScanDetectionResult(
                resultingPhase = if (confirmed) ScanPhaseKind.RECORDING else ScanPhaseKind.EVENT_FOUND,
                transitionedToEventFound = true,
                confirmedEvent = confirmed,
                updatedRecording = false,
            )

        ScanPhaseKind.EVENT_FOUND ->
            ScanDetectionResult(
                resultingPhase = if (confirmed) ScanPhaseKind.RECORDING else ScanPhaseKind.EVENT_FOUND,
                transitionedToEventFound = false,
                confirmedEvent = confirmed,
                updatedRecording = false,
            )

        ScanPhaseKind.RECORDING ->
            ScanDetectionResult(
                resultingPhase = ScanPhaseKind.RECORDING,
                transitionedToEventFound = false,
                confirmedEvent = false,
                updatedRecording = distinctDeviceCountChanged,
            )
    }
}

/** The result of an explicit (non-detection-driven) phase action. */
public class ScanPhaseActionResult internal constructor(
    public val resultingPhase: ScanPhaseKind,
    public val applied: Boolean,
)

/** `IDLE -> SENSING`, unconditional — `SensingCoordinator.startSensing()`. */
public fun scanPhaseAfterStartSensing(): ScanPhaseKind = ScanPhaseKind.SENSING

/** Any phase `-> IDLE`, unconditional — explicit stop/reset, never detection-driven. */
public fun scanPhaseAfterStopSensing(): ScanPhaseKind = ScanPhaseKind.IDLE

/**
 * `RECORDING -> SIGNAL_LOST`, freezing the recorded count. A no-op from any
 * other phase — mirrors iOS's `simulateSignalLost()` guard
 * (`guard case .recording = phase else { return }`).
 */
public fun scanPhaseAfterSignalLost(currentPhase: ScanPhaseKind): ScanPhaseActionResult =
    if (currentPhase == ScanPhaseKind.RECORDING) {
        ScanPhaseActionResult(resultingPhase = ScanPhaseKind.SIGNAL_LOST, applied = true)
    } else {
        ScanPhaseActionResult(resultingPhase = currentPhase, applied = false)
    }

/**
 * `SIGNAL_LOST -> RECORDING`, resuming in place — never a restart, and only
 * ever an explicit user action, never automatic on the next detection. A
 * no-op from any other phase — mirrors iOS's `resumeSensing()` guard
 * (`guard case .signalLost = phase else { return }`).
 */
public fun scanPhaseAfterResumeSensing(currentPhase: ScanPhaseKind): ScanPhaseActionResult =
    if (currentPhase == ScanPhaseKind.SIGNAL_LOST) {
        ScanPhaseActionResult(resultingPhase = ScanPhaseKind.RECORDING, applied = true)
    } else {
        ScanPhaseActionResult(resultingPhase = currentPhase, applied = false)
    }
