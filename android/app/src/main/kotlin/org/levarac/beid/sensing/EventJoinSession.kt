package org.levarac.beid.sensing

import kotlinx.coroutines.flow.StateFlow
import org.levarac.beid.shared.event.NearbyEventSearchOutcome

/**
 * A nearby beacon candidate. Its name is an unauthenticated B005 announcement;
 * the optional ID and period exist only after the shared reducer accepts the
 * OPEN definition, its hash binding, and the operator lookup route.
 */
data class NearbyEventCard(
    val beaconDisplayName: String?,
    val eventIdHex: String? = null,
    /**
     * The event's validity window **for rendering only**, and never the
     * authority for whether this event may be joined (beid#374).
     *
     * The join decision reads
     * [org.levarac.parallax.discovery.NearbyEventCandidate.definitionValidFromEpochSeconds]
     * — the window the registry promotion retained — and re-checks it at the
     * moment of the tap. These two are not copies of one value that happen to
     * be spelled twice: **this one can be absent while the authoritative one
     * is present**, because it is published only for a candidate the card list
     * currently considers joinable and is dropped once it lapses. A reader
     * reaching here for a join check therefore gets `null` and concludes there
     * is no window, while the real one is sitting on the candidate. A silent
     * absence reads as a legitimate empty case, which is what makes it worse
     * than a wrong value.
     *
     * Named `display…` so that reaching for it in a decision is visibly wrong
     * at the call site rather than merely plausible.
     */
    val displayValidFromEpochSeconds: Long? = null,
    val displayValidUntilEpochSeconds: Long? = null,
    /** Stable B005 candidate identity; unlike list position, it survives reordering. */
    val eventCodeHashHex: String,
)

/**
 * The narrow surface [EventJoinViewModel][org.levarac.beid.ui.screens.EventJoinViewModel]
 * needs from a join session — [EventJoinCoordinator]'s production
 * implementation, or a fake in tests. Exists because [EventJoinCoordinator]
 * itself requires a real `Activity` and eagerly constructs a real
 * `BarnardEngine`, which makes it unconstructable in a plain JVM test. This
 * interface deliberately excludes `onRequestPermissionsResult`/`dispose`/
 * engine construction — those stay Activity-lifecycle glue, called directly
 * by `MainActivity`, not a ViewModel concern.
 */
interface EventJoinSession {
    val state: StateFlow<EventJoinUiState>

    /** Every nearby candidate is displayable; only cards with an Event ID are joinable. */
    val nearbyEventCards: StateFlow<List<NearbyEventCard>>

    /**
     * Whether the surface should still be searching or should now offer the
     * paste rescue route (beid#463).
     *
     * Separate from [nearbyEventCards] because it is not a function of them
     * alone: a search that has found nothing joinable for twenty seconds and
     * one that started two seconds ago look identical in the card list, and
     * only one of them means the participant is stuck.
     */
    val nearbyEventSearchOutcome: StateFlow<NearbyEventSearchOutcome>

    /**
     * Whether Barnard dropped nearby events it could not keep
     * (`additionalEventsOmitted`; the SDK holds 32 hashes).
     *
     * Surfaced because **a silent absence reads as a legitimate empty case**:
     * a participant looking at the card list concludes "that is what is
     * nearby", and it is not. Never a count — the SDK reports that it dropped
     * events, never how many, and an invented denominator would be the same
     * defect one step along (beid#450).
     */
    val nearbyEventsOmitted: StateFlow<Boolean>

    /** Starts passive nearby-event discovery when the EventJoin surface becomes active. */
    fun startNearbyEventDiscovery()

    fun joinEvent(code: String)

    /**
     * Joins the nearby candidate with this event-code hash (beid#374).
     *
     * Takes the hash rather than the Event ID on purpose. The hash is the
     * stable candidate identity — see [NearbyEventCard.eventCodeHashHex] — so
     * the session re-reads the *current* candidate and re-checks it at the
     * moment of the tap, instead of joining an Event ID that a click closure
     * captured when the list was built. A candidate's tier can fall between
     * render and tap, and a card's `enabled` flag is a display projection,
     * never the authority for whether a join may proceed.
     */
    fun joinNearbyEvent(eventCodeHashHex: String)

    fun openAppSettings()

    /**
     * Triggers the real Android runtime-permission flow for BLE
     * (BLUETOOTH_SCAN/CONNECT/ADVERTISE) — the same underlying
     * `engine.requestPermissions` call [joinEvent] makes — so onboarding's
     * "Allow Bluetooth" CTA (`BluetoothPermissionScreen`) actually produces
     * the OS prompt its copy promises, instead of being purely cosmetic.
     *
     * Deliberately does not branch on the resulting `BarnardPermissionResult`
     * granted/denied content: onboarding routing after this call is
     * radio-power-only ([BluetoothRadioMonitor.isOn]), mirroring iOS's
     * `evaluateBluetoothState()`, which likewise never consults permission
     * grant/denial when deciding where to route. A denied-permission
     * onboarding state is out of scope here; `EventJoinUiState.PermissionDenied`
     * on the join screen already covers a hard denial reached later.
     */
    fun requestBluetoothPermission(onComplete: () -> Unit)

    /**
     * Manual trigger for `RECORDING -> SIGNAL_LOST` (beid#120) — Android has
     * no real BLE signal-loss *detection* yet, only this explicit action,
     * mirroring iOS's `SensingCoordinator.simulateSignalLost()`. A no-op
     * unless the current [EventJoinUiState.Sensing] phase is
     * [ScanPhase.Recording].
     */
    fun simulateSignalLost()

    /**
     * Resumes `SIGNAL_LOST -> RECORDING` in place — never a restart, so
     * nothing already recorded is discarded. Mirrors iOS's
     * `SensingCoordinator.resumeSensing()`. A no-op unless the current
     * [EventJoinUiState.Sensing] phase is [ScanPhase.SignalLost].
     */
    fun resumeSensing()

    /**
     * Leaves the currently-joined event — the Account screen's "Leave Event"
     * action (beid#126). Mirrors iOS's `SensingCoordinator.leaveEvent()`
     * (`engine.leaveEvent()` + resetting `joinedEventCode`), adapted for this
     * session's richer local state (a [ScanPhase] and device-accounting
     * bookkeeping iOS's simple `joinedEventCode: String?` doesn't carry): the
     * production implementation calls the SDK's `leaveEvent()` and then
     * resets native bookkeeping back to [EventJoinUiState.Idle] so the UI
     * reflects "no active session" afterward. Callers gate this action's
     * availability on session activity themselves — see [state].
     */
    fun leaveEvent()

    /**
     * Whether this session's Recording-phase entrance ceremony
     * ("Proof Collected") has already been shown — mirrors iOS's
     * `SensingCoordinator.recordingCeremonyShown`
     * (`ios/Beid/Sensing/SensingCoordinator.swift`). `false` for a fresh
     * session; set once via [markRecordingCeremonyShown] and never reset by
     * [resumeSensing] — a signal-lost → resume cycle must not replay the
     * ceremony, only a genuinely new session (a fresh [joinEvent]/
     * [joinNearbyEvent]) resets it.
     */
    val recordingCeremonyShown: Boolean

    /**
     * Marks [recordingCeremonyShown] `true` — called once the UI signals
     * the entrance ceremony has been shown for this session's Recording
     * phase, mirroring iOS's `RecordingView.onAppear` calling
     * `sensing.markRecordingCeremonyShown()`.
     */
    fun markRecordingCeremonyShown()
}
