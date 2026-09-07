package org.levarac.beid.sensing

import android.app.Activity
import java.io.File
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.levarac.barnard.BarnardB005EnvelopeV2
import org.levarac.barnard.BarnardEngine
import org.levarac.barnard.BarnardEvent
import org.levarac.barnard.BarnardEventInfoEnvelopeV2Event
import org.levarac.barnard.BarnardRegistryAgreement
import org.levarac.barnard.BarnardRelayDecision
import org.levarac.barnard.BarnardRelayDecisionEvent
import org.levarac.barnard.BarnardPermissionResult
import org.levarac.parallax.discovery.NearbyEventCandidates
import org.levarac.parallax.registry.RegistryClient
import org.levarac.beid.persistence.BindingRecord
import org.levarac.beid.persistence.BindingRecordStore
import org.levarac.beid.persistence.SelfProofRecord
import org.levarac.beid.persistence.SelfProofRecordStore
import org.levarac.beid.persistence.UnsentWindowLedgerStore
import org.levarac.beid.registry.RegistryDependencies

/**
 * UI-facing state for [EventJoinCoordinator]. Mirrors the shape of iOS's
 * `SensingCoordinator` phases (`ios/Beid/Sensing/SensingCoordinator.swift`).
 * [Sensing] carries the native [ScanPhase] driven by
 * `org.levarac.beid.shared.sensing` (beid#116/#120) once the event join
 * succeeds — see [EventJoinCoordinator]'s detection handling.
 */
sealed class EventJoinUiState {
    data object Idle : EventJoinUiState()
    data object RequestingPermission : EventJoinUiState()
    data class Sensing(val phase: ScanPhase) : EventJoinUiState()
    data object PermissionDenied : EventJoinUiState()
    data object JoinFailed : EventJoinUiState()
}

/**
 * Maps a resolved [BarnardPermissionResult] to the [EventJoinUiState] it
 * produces when the request did not end in a full grant. Callers are
 * expected to handle the "granted with full scan+advertise capability"
 * case themselves before reaching here (it carries side effects — starting
 * the join — that this pure function must not perform), so a fully-granted
 * [BarnardPermissionResult.Granted] is out of this function's contract.
 *
 * [BarnardPermissionResult.Failed] (SDK-reported `E_NO_ACTIVITY` or
 * `E_PERMISSION_REQUEST_IN_PROGRESS`, per decompiled Barnard 0.3.0) is a
 * caller/lifecycle failure, never a permission denial, so it maps to
 * [EventJoinUiState.JoinFailed] rather than [EventJoinUiState.PermissionDenied]
 * (see issue #127).
 */
fun mapPermissionResultToState(result: BarnardPermissionResult): EventJoinUiState = when (result) {
    is BarnardPermissionResult.Granted -> EventJoinUiState.PermissionDenied
    is BarnardPermissionResult.Failed -> EventJoinUiState.JoinFailed
}

/**
 * Wraps Barnard through [BarnardEventJoinEngine] (permission request →
 * `joinEvent` → `startAuto`)
 * behind the native [ScanPhase] state machine driven by
 * `org.levarac.beid.shared.sensing` (beid#116/#120) — the Android
 * counterpart of iOS's `SensingCoordinator`, scoped to this app's one
 * screen. This adapter holds no threshold or transition-graph logic of its
 * own; every phase decision is a single call into [applyPhaseDecision] or
 * one of the explicit-action functions in `ScanPhase.kt`.
 */
class EventJoinCoordinator internal constructor(
    private val engine: EventJoinEngine,
    private val nowEpochMillis: () -> Long,
    private val coroutineScope: CoroutineScope,
    private val registryClient: RegistryClient? = null,
    private val sensingCryptography: SensingCryptography,
    private val selfProofRecordStore: SelfProofRecordStore,
    private val bindingRecordStore: BindingRecordStore,
    private val randomSource: OwnerKeyRandomSource = SecureRandomOwnerKeySource(),
    ledgerFilesDir: File? = null,
    injectedWindowAccumulator: WindowObservationAccumulator? = null,
    windowObservationRuntimeOwner: WindowObservationRuntimeOwner? = null,
) : EventJoinSession {
    constructor(activity: Activity) : this(
        engine = BarnardEventJoinEngine(activity),
        nowEpochMillis = System::currentTimeMillis,
        coroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
        registryClient = RegistryDependencies.createClient(),
        sensingCryptography = BarnardSensingCryptography(activity.applicationContext),
        selfProofRecordStore = SelfProofRecordStore(SelfProofRecordStore.defaultFile(activity.filesDir)),
        bindingRecordStore = BindingRecordStore(BindingRecordStore.defaultFile(activity.filesDir)),
        ledgerFilesDir = activity.filesDir,
        windowObservationRuntimeOwner = ProcessWindowObservationRuntimeOwner,
    )

    private val accounting = ScanDeviceAccounting()
    private val nearbyDiscovery = NearbyEventDiscoverySession(
        nowEpochMillis = nowEpochMillis,
        coroutineScope = coroutineScope,
        registry = registryClient?.let(::RegistryClientNearbyEventRegistry),
    )

    private val _state = MutableStateFlow<EventJoinUiState>(EventJoinUiState.Idle)
    override val state: StateFlow<EventJoinUiState> = _state.asStateFlow()
    override val nearbyEventCards: StateFlow<List<NearbyEventCard>> = nearbyDiscovery.cards
    val nearbyEventCandidates: StateFlow<NearbyEventCandidates> = nearbyDiscovery.candidates

    /**
     * Everything barnard's relay verifier is allowed to read, republished on
     * the main thread whenever discovery state or the joined event moves.
     *
     * `@Volatile` because the verifier runs inline on whichever thread the
     * GATT read arrived on. The value is immutable, so a verifier either sees
     * the previous gate state or the next one, never a half-built one.
     */
    @Volatile
    private var relayGateState = ParticipantRelayGateState(
        candidates = nearbyDiscovery.candidates.value,
        verifiedDefinitionsByHash = emptyMap(),
        joinedEventIdHex = null,
    )

    /** The relay verifier, configured on join and cleared on every stop. */
    private val relayVerifier = ParticipantRelayVerifier { relayGateState }

    /** Repeating 30-second wake-up that runs the relay's lease decisions. */
    private var relayCadenceJob: Job? = null

    /**
     * The most recent spec 134 decision, for visibility only. It never feeds a
     * card, a tally, or a phase: hop counts and relay volume say nothing about
     * an event (spec 134, "Security and abuse considerations").
     */
    internal var lastRelayDecision: ParticipantRelayDecision? = null
        private set

    /** Source of truth for the current [ScanPhase] — mirrors [_state]'s payload once `Sensing` is reached. */
    private var scanPhase: ScanPhase = ScanPhase.Idle
    private var discoveryOnlyScanOwned = false
    private var disposed = false
    @Volatile
    private var observationContextRequestOwner: Any? = null
    private val windowObservationRuntime = if (injectedWindowAccumulator == null && ledgerFilesDir != null) {
        (windowObservationRuntimeOwner ?: WindowObservationRuntimeOwner()).acquire(
            filesDir = ledgerFilesDir,
            cryptography = sensingCryptography,
            nowEpochSeconds = { nowEpochMillis() / 1_000.0 },
        )
    } else {
        null
    }
    private val windowAccumulator = injectedWindowAccumulator ?: windowObservationRuntime?.accumulator

    /**
     * Set the instant this session's [ScanPhase] first confirms into
     * [ScanPhase.Recording] (a "Proof" exists from that point on) — mirrors
     * iOS's `activeProofId`. `null` means no self-proof/binding is due at
     * session end: the session never reached `Recording`.
     */
    private var activeProofId: UUID? = null

    /** Wallet connect+binding lifecycle for the currently recording event — see [EventBindingState]. */
    var bindingState: EventBindingState = EventBindingState.None
        private set

    /** Fixed once per binding attempt and reused across the wallet signature and the later owner-key wallet-ack — see [beginBinding]. */
    private var pendingBindingMessage: BindingMessage? = null

    /**
     * Fired exactly once per session, the instant [scanPhase] first confirms
     * into [ScanPhase.Recording] and this session's `Proof` identity
     * ([activeProofId]) is created — mirrors iOS's `onProofCollected`
     * (`ios/Beid/Sensing/SensingCoordinator.swift`). Carries the just-created
     * [activeProofId], the recording session's `eventCode`, and the
     * `peersVerified` count at the moment of confirmation.
     *
     * **Why this exact position (immediately after [activeProofId] is
     * assigned in [onPhaseDecided], before any other side effect) matters:**
     * Android has no counterpart to iOS's `SelfProofCheckpointStore` — PR
     * #314 disclosed that a process kill before [leaveEvent]/[dispose]
     * silently drops the self-proof for the whole session. Firing this at
     * the earliest possible point lets a future consumer (this issue's own
     * still-open ledger-writer fork decision) create its durable row for
     * the session right away, degrading the worst-case loss from "the
     * session disappears entirely" to "the session is recorded, only its
     * self-proof is missing."
     *
     * **Threading, verified (not assumed):** always Android's main thread.
     * This fires from [onPhaseDecided], called from [handleDetection],
     * called from [handleBarnardEvent] — which is [engine]'s `onEvent`
     * (Barnard's `BarnardEngine.onEvent`, `org.levarac.barnard` 0.5.0). No
     * contract for this is documented anywhere in this repository or in
     * barnard's shipped artifact; the answer below comes from disassembling
     * the actual resolved `barnard-0.5.0.aar`'s `classes.jar` in this
     * project's Gradle cache (`javap -p -c org.levarac.barnard.BarnardEngine`):
     * `BarnardEngine` constructs `private val mainHandler =
     * Handler(Looper.getMainLooper())` once in its constructor, and every one
     * of its `emit*` methods (`emitState`, `emitConstraint`, `emitError`,
     * `emitEventInfoHint`, `emitDetection`, `emitRssiUpdate` — the
     * `BarnardEvent.Detection` case this hook cares about included) posts the
     * actual `onEvent.invoke(...)` call through `mainHandler.post { ... }`
     * before returning, regardless of which underlying thread triggered the
     * emit (BLE/GATT callback threads are never the main thread). This is a
     * different callback source than `RegistryClient`, whose completion
     * callbacks run on `Dispatchers.Default` and needed the
     * `coroutineScope.launch { }` wrapping fixed in `1c7db20` — do not assume
     * the two share a dispatcher just because both are Barnard-adjacent.
     */
    var onProofCollected: ((proofId: UUID, eventCode: String, peersVerified: Int) -> Unit)? = null

    /**
     * Fired every time [scanPhase] stays [ScanPhase.Recording] across a
     * detection but its `peersVerified` count changes — mirrors iOS's
     * `onPeersVerifiedChanged`. Never fires on the detection that first
     * confirms `Recording` ([onProofCollected] owns that transition), and
     * never fires while [scanPhase] is anything other than `Recording`
     * both before and after the detection (`EventFound`/`Sensing`/`Idle`/
     * `SignalLost` transitions are excluded by construction — see
     * [onPhaseDecided]).
     *
     * **Threading:** identical guarantee to [onProofCollected] — this also
     * fires from [onPhaseDecided]/[handleDetection]/[handleBarnardEvent],
     * i.e. always on Android's main thread per the verified `BarnardEngine`
     * `mainHandler.post` contract documented on [onProofCollected]'s doc
     * comment; see there for the evidence.
     */
    var onPeersVerifiedChanged: ((proofId: UUID, peersVerified: Int) -> Unit)? = null

    /**
     * Fired whenever this session's self-proof and/or binding on-device
     * record changes existence — from [finalizeSelfProofIfNeeded] right
     * after a self-proof is persisted, and from [completeBinding] right
     * after a binding is persisted. Both booleans are recomputed from the
     * stores this class already holds ([selfProofRecordStore]/
     * [bindingRecordStore]), never from a second store instance over the
     * same file — a second instance would silently miss the other
     * instance's writes, since the underlying `JsonRecordFileStore` loads
     * once at construction.
     *
     * **Threading, verified per call site (not assumed):**
     * - [finalizeSelfProofIfNeeded]'s two call sites are ordinary method
     *   calls, not Barnard callbacks: [leaveEvent] is invoked from
     *   `AccountScreen.kt`'s "Leave Event" button
     *   (`onClick = viewModel::leaveEvent`, a Compose click handler, which
     *   Compose always dispatches on the main thread), and [dispose] is
     *   invoked from `MainActivity.onDestroy()` (an Activity lifecycle
     *   callback, also always the main thread). Both confirmed by reading
     *   their actual callers, not inferred by analogy.
     * - [completeBinding] has no production caller yet — #124 (wallet-connect
     *   UI) has not landed, so this branch is reachable only from tests
     *   today. Once #124 wires a caller, that caller's own thread must be
     *   checked again before relying on this being main-thread there; do
     *   not assume it inherits this guarantee without rechecking.
     */
    var onProofSignatureStateChanged: ((proofId: UUID, hasSelfProof: Boolean, hasBinding: Boolean) -> Unit)? = null

    /** See [EventJoinSession.recordingCeremonyShown]. Reset in [resetSessionState], never by [resumeSensing]. */
    override var recordingCeremonyShown: Boolean = false
        private set

    override fun markRecordingCeremonyShown() {
        recordingCeremonyShown = true
    }

    init {
        engine.onEvent = ::handleBarnardEvent
        // Definitions are written before the snapshot that reflects them is
        // emitted, so collecting the snapshot picks up both together.
        coroutineScope.launch {
            nearbyDiscovery.candidates.collect { republishRelayGateState(candidates = it) }
        }
    }

    /**
     * Rebuilds the immutable value the relay verifier reads. Called on the
     * main thread only.
     */
    private fun republishRelayGateState(
        candidates: NearbyEventCandidates = relayGateState.candidates,
        joinedEventIdHex: String? = relayGateState.joinedEventIdHex,
    ) {
        relayGateState = ParticipantRelayGateState(
            candidates = candidates,
            verifiedDefinitionsByHash = nearbyDiscovery.verifiedDefinitionsByHash(),
            joinedEventIdHex = joinedEventIdHex,
        )
    }

    /**
     * Turns relay on for this session. Called only once permissions are
     * granted for both Scan and Advertise: a device that cannot advertise
     * cannot re-broadcast anything, and offering to would be a lie.
     */
    private fun startParticipantRelay() {
        engine.configureParticipantRelay(relayVerifier)
        relayCadenceJob?.cancel()
        relayCadenceJob = coroutineScope.launch {
            while (true) {
                delay(RELAY_DECISION_BOUNDARY_MILLIS)
                engine.advanceParticipantRelay()
            }
        }
    }

    /**
     * Turns relay off. Idempotent, and called from every exit: leaving the
     * event, ending the session, a permission refusal, and disposal. Passing
     * a null verifier is what makes barnard drop the lease, the density
     * handles and the cached envelope.
     */
    private fun stopParticipantRelay() {
        relayCadenceJob?.cancel()
        relayCadenceJob = null
        engine.configureParticipantRelay(null)
        republishRelayGateState(joinedEventIdHex = null)
    }

    override fun joinEvent(code: String) {
        if (!canBeginJoin()) return
        _state.value = EventJoinUiState.RequestingPermission
        engine.requestPermissions { result ->
            if (disposed || scanPhase != ScanPhase.Idle || _state.value != EventJoinUiState.RequestingPermission) {
                return@requestPermissions
            }
            if (result is BarnardPermissionResult.Granted && result.status.canScan && result.status.canAdvertise) {
                windowObservationRuntime?.beginEvent(code)
                engine.joinEvent(code)
                resolveObservationContext(code)
                discoveryOnlyScanOwned = false
                engine.startAuto()
                startParticipantRelay()
                startSensing()
            } else {
                stopParticipantRelay()
                _state.value = mapPermissionResultToState(result)
            }
        }
    }

    private fun canBeginJoin(): Boolean =
        !disposed &&
            scanPhase == ScanPhase.Idle &&
            _state.value !is EventJoinUiState.RequestingPermission &&
            _state.value !is EventJoinUiState.Sensing

    override fun joinNearbyEvent(eventIdHex: String) = joinEvent(eventIdHex)

    private fun startSensing() {
        resetSessionState()
        scanPhase = applyStartSensing()
        _state.value = EventJoinUiState.Sensing(scanPhase)
    }

    private fun handleBarnardEvent(event: BarnardEvent) {
        if (disposed) return
        when (event) {
            is BarnardEvent.EventInfoHint -> {
                val hint = event.hint
                nearbyDiscovery.recordHint(
                    peripheralId = hint.peripheralId,
                    eventDisplayName = hint.eventInfo.eventDisplayName,
                    eventCodeHash = hint.eventInfo.eventCodeHash,
                    census = hint.eventInfo.census,
                    additionalNamesOmitted = hint.additionalNamesOmitted,
                    additionalEventsOmitted = hint.additionalEventsOmitted,
                )
            }
            is BarnardEvent.EventInfoEnvelopeV2 -> {
                handleEventInfoEnvelopeV2(event.envelope)
            }
            is BarnardEvent.RelayDecision -> {
                handleRelayDecision(event.relay)
            }
            is BarnardEvent.Detection -> {
                val detection = event.detection
                handleDetection(
                    enin = detection.enin,
                    rpid = detection.rpid,
                    detectedDisplayId = detection.detectedDisplayId,
                    reporterRpid = detection.reporterRpid,
                )
            }
            else -> Unit
        }
    }

    /**
     * Mirrors iOS's `SensingCoordinator.handleEventInfoEnvelopeV2`.
     *
     * A receipt that is not `RADIO_SELF_VERIFIED` becomes no candidate:
     * barnard's `verify` returns nothing for both a malformed container and a
     * bad signature, so an unverified receipt has no event-code hash, no
     * display name, and nothing to describe. It is counted rather than
     * silently discarded, so the drop stays observable.
     *
     * The raw container travels with the verified receipt because spec 134
     * re-broadcast is signature-preserving: the relay serves these exact bytes
     * with only `relayHopCount` changed.
     *
     * The agreement closure handed downstream is barnard's own pure
     * comparison bound to this envelope. This host never re-implements it, and
     * never assigns `REGISTRY_VERIFIED` itself outside the shared reducer.
     */
    /**
     * Records the latest spec 134 decision so relay is observable at all.
     *
     * Visibility only. Nothing downstream reads it, and nothing may: a relayed
     * candidate is an ordinary card, its hop count is never shown, and relay
     * volume is never evidence about an event.
     */
    internal fun handleRelayDecision(event: BarnardRelayDecisionEvent) {
        lastRelayDecision = ParticipantRelayDecision(
            decision = event.decision,
            payloadDigestHex = event.payloadDigest
                .joinToString("") { "%02x".format(it.toInt() and 0xff) },
            hop = event.hop,
            reason = event.reason,
        )
    }

    private fun handleEventInfoEnvelopeV2(event: BarnardEventInfoEnvelopeV2Event) {
        val envelope = event.verifiedEnvelope
        if (envelope == null) {
            nearbyDiscovery.recordUnverifiedEnvelope()
            return
        }
        nearbyDiscovery.recordRadioSelfVerifiedEnvelope(
            peripheralId = event.peripheralId,
            eventDisplayName = envelope.eventDisplayName,
            eventCodeHash = envelope.eventCodeHash,
            rawContainer = event.rawContainer,
        ) { definition -> BarnardB005EnvelopeV2.registryAgreement(envelope, definition) is BarnardRegistryAgreement.Agrees }
    }

    /**
     * Mirrors iOS's `SensingCoordinator.handleDetection(enin:rpid:detectedDisplayId:)`.
     * Runs the native counting bookkeeping unconditionally, then calls
     * through to [applyPhaseDecision] regardless of [scanPhase] — `IDLE`/
     * `SIGNAL_LOST` are not special-cased out here; `applyScanDetection`
     * (beid#116) already reports those as no-ops via its result flags, and
     * duplicating that "ignore" branch natively would be exactly the kind
     * of re-derived transition AGENTS.md's ownership boundary forbids.
     */
    private fun handleDetection(enin: Long, rpid: String, detectedDisplayId: String?, reporterRpid: String?) {
        val distinctDeviceCountChanged = accounting.record(enin = enin, rpid = rpid, detectedDisplayId = detectedDisplayId)

        val session = when (val phase = scanPhase) {
            is ScanPhase.EventFound -> phase.session
            is ScanPhase.Recording -> phase.session
            is ScanPhase.SignalLost -> phase.session
            ScanPhase.Sensing -> ScanEventSession(eventCode = engine.getCurrentEventCode() ?: UNKNOWN_EVENT_CODE)
            ScanPhase.Idle -> ScanEventSession(eventCode = UNKNOWN_EVENT_CODE)
        }

        val previousPhase = scanPhase
        scanPhase = applyPhaseDecision(
            currentPhase = scanPhase,
            session = session,
            coPresentDeviceCount = accounting.coPresentDeviceCount,
            distinctDeviceCount = accounting.distinctDeviceCount,
            distinctDeviceCountChanged = distinctDeviceCountChanged,
            eventConfirmThreshold = BeidConfig.eventConfirmThreshold,
        )
        onPhaseDecided(previousPhase)
        windowAccumulator?.observe(
            enin = enin,
            rpid = rpid,
            reporterRpid = reporterRpid,
            recording = scanPhase is ScanPhase.Recording,
            eventCode = engine.getCurrentEventCode(),
        )
        _state.value = EventJoinUiState.Sensing(scanPhase)
    }

    /**
     * Threshold-confirm (mirrors iOS's `beginRecording`): the instant
     * [scanPhase] first confirms into [ScanPhase.Recording] — i.e. this
     * exact detection is the one [applyPhaseDecision] reports via
     * `result.confirmedEvent` — creates this session's "Proof" identity
     * ([activeProofId]) and marks the event [EventBindingState.PendingConnect]
     * for the next binding opportunity. A no-op on every other transition,
     * including staying in/updating [ScanPhase.Recording].
     */
    private fun onPhaseDecided(previousPhase: ScanPhase) {
        val recording = scanPhase as? ScanPhase.Recording ?: return
        if (previousPhase is ScanPhase.Recording) {
            if (previousPhase.peersVerified != recording.peersVerified) {
                activeProofId?.let { onPeersVerifiedChanged?.invoke(it, recording.peersVerified) }
            }
            return
        }
        activeProofId = UUID.randomUUID()
        onProofCollected?.invoke(activeProofId!!, recording.session.eventCode, recording.peersVerified)
        bindingState = EventBindingState.PendingConnect(recording.session)
    }

    /** Mirrors iOS's `currentBindingEvent` — the session self-proof/binding read from once [scanPhase] implies an active recording. */
    private fun currentRecordingSession(): ScanEventSession? = when (val phase = scanPhase) {
        is ScanPhase.Recording -> phase.session
        is ScanPhase.SignalLost -> phase.session
        else -> null
    }

    override fun simulateSignalLost() {
        if (_state.value !is EventJoinUiState.Sensing) return
        scanPhase = applySignalLost(scanPhase)
        _state.value = EventJoinUiState.Sensing(scanPhase)
    }

    override fun resumeSensing() {
        if (_state.value !is EventJoinUiState.Sensing) return
        scanPhase = applyResumeSensing(scanPhase)
        _state.value = EventJoinUiState.Sensing(scanPhase)
    }

    /**
     * Mirrors iOS's `SensingCoordinator.leaveEvent()` (`engine.leaveEvent()`
     * + resetting `joinedEventCode`), adapted for this class's richer local
     * state. iOS's version is minimal because `joinedEventCode: String?` is
     * its only local session bookkeeping; this class additionally carries
     * [scanPhase] and [accounting], so a bare `engine.leaveEvent()` call
     * alone would leave both stale (still reporting a [ScanPhase]/[state] as
     * if a session were active). [applyStopSensing] is the same "any phase ->
     * IDLE" shared-authorized transition [dispose] already uses — reusing it
     * here (rather than deciding a new transition) keeps the resulting phase
     * decision inside the existing shared-owned contract instead of inventing
     * a second one.
     *
     * **Why this also finalizes self-proof today, and why that is not a
     * permanent fact about `leaveEvent()` itself:** the lifecycle wiring
     * (native decides where a session ends) is not what makes this correct
     * — it is the current product answer to "does leaving an event end the
     * session?" On iOS, no: `SensingCoordinator.leaveEvent()` clears the
     * joined event code and hands control back to passive nearby-event
     * discovery: `engine.leaveEvent()` does not stop scanning, and
     * `clearNearbyEventDiscovery()` only clears now-stale *candidates*, not
     * discovery itself — sensing continues, just unattached to any one
     * event. On Android, yes, because that discovery-mode continuation does
     * not exist yet: [leaveEvent] already fully resets [scanPhase] to
     * `Idle` via [applyStopSensing] and clears [nearbyDiscovery], so leaving
     * an event and ending the session are, today, the same act by
     * construction — there is no "leave this event, keep looking for
     * another" path for self-proof finalization to wrongly interrupt.
     *
     * **Revisit condition**: issue #141 (participation surface replacing
     * manual `EventCode` entry with event cards and zero-tap auto-start)
     * is what would give Android that discovery-mode continuation. Once it
     * lands, a user leaving one event to look for another would have this
     * function silently seal their self-proof mid-stream — at that point,
     * [finalizeSelfProofIfNeeded] must move off [leaveEvent] and onto
     * whatever function actually ends the session then (mirroring iOS's
     * own split, where finalization lives on `stopSensing()`/`reset()`,
     * not on `leaveEvent()`). Do not assume this call site is still correct
     * once #141 lands without rechecking it.
     */
    override fun leaveEvent() {
        if (disposed) return
        windowAccumulator?.close()
        finalizeSelfProofIfNeeded()
        engine.leaveEvent()
        stopParticipantRelay()
        discoveryOnlyScanOwned = false
        nearbyDiscovery.reset()
        scanPhase = applyStopSensing()
        resetSessionState()
        _state.value = EventJoinUiState.Idle
    }

    private fun resolveObservationContext(eventCode: String) {
        windowObservationRuntime?.updateContext(null)
        val requestOwner = Any()
        observationContextRequestOwner = requestOwner
        val client = registryClient ?: return
        client.resolveEventId(eventCode) { lookup ->
            if (observationContextRequestOwner !== requestOwner) return@resolveEventId
            val eventId = lookup.eventIdHex ?: return@resolveEventId
            client.resolveEventDefinition(eventId, org.levarac.parallax.registry.safeRegistryReadPin(), nowEpochMillis() / 1_000L) { result ->
                val verified = result.context ?: return@resolveEventDefinition
                coroutineScope.launch {
                    acceptVerifiedObservationContext(
                        WindowObservationContext(
                            eventCode = eventCode,
                            eventIdHex = verified.eventIdHex,
                            eventDefinitionDigestHex = verified.definitionHashHex,
                        ),
                        requestOwner,
                    )
                }
            }
        }
    }

    internal fun acceptVerifiedObservationContext(context: WindowObservationContext) {
        val requestOwner = observationContextRequestOwner ?: return
        acceptVerifiedObservationContext(context, requestOwner)
    }

    private fun acceptVerifiedObservationContext(context: WindowObservationContext, requestOwner: Any) {
        if (!disposed && observationContextRequestOwner === requestOwner && engine.getCurrentEventCode() == context.eventCode) {
            windowObservationRuntime?.updateContext(context)
            // The relay gate opens here and nowhere else. This is the only
            // point where the joined event has a canonical id that came from
            // this host's own authenticated registry read, and relaying an
            // event this device cannot name that precisely is exactly what
            // "one device, one event" forbids.
            republishRelayGateState(joinedEventIdHex = context.eventIdHex)
        }
    }

    /**
     * Builds, signs, and persists this session's self-proof, if one is due
     * — mirrors iOS's `finalizeSelfProofIfNeeded()`. `null` (nothing
     * persisted) if there is no Proof for this session ([activeProofId]
     * unset — never reached [ScanPhase.Recording]) or no ENIN window was
     * ever observed. Idempotent per session: [resetSessionState] clears
     * [activeProofId] right after, so a second call (e.g. [dispose] after
     * [leaveEvent] already ran) finds nothing to do.
     */
    private fun finalizeSelfProofIfNeeded(): SelfProofRecord? {
        val proofId = activeProofId ?: return null
        val eventCode = currentRecordingSession()?.eventCode ?: return null
        val start = accounting.firstWindowEnin ?: return null
        val end = accounting.lastWindowEnin ?: return null

        val eventIdHash = EventIdHash.compute(eventCode)
        val eventSigningPublicKey = sensingCryptography.eventSigningPublicKey(eventCode)
        val ownerPublicKey = sensingCryptography.ownerPublicKey()
        val signature = sensingCryptography.signSelfProof(eventIdHash, eventSigningPublicKey, start, end)
            ?: return null

        val record = SelfProofRecord(
            proofId = proofId,
            eventCode = eventCode,
            eventIdHash = eventIdHash,
            eventSigningPublicKey = eventSigningPublicKey,
            eninStart = start,
            eninEnd = end,
            ownerPublicKey = ownerPublicKey,
            signature = signature,
        )
        selfProofRecordStore.add(record)
        onProofSignatureStateChanged?.invoke(proofId, true, bindingRecordStore.recordForProofId(proofId) != null)
        return record
    }

    private fun resetSessionState() {
        accounting.reset()
        activeProofId = null
        bindingState = EventBindingState.None
        pendingBindingMessage = null
        recordingCeremonyShown = false
    }

    // MARK: - Wallet connect+binding (mirrors iOS's `SensingCoordinator`
    // §5.6/`docs/specs/barnard-binding-conformance.md` §2.3/§2.4). No
    // wallet-connect UI wires into this yet (#124's scope) — see this
    // task's handoff.

    /**
     * Starts (or resumes) this attempt, moving to [EventBindingState.Connecting]
     * and returning the `0x`-prefixed hex the wallet's `personal_sign` must
     * sign — the UTF-8 bytes of the literal `barnard-account-binding:v1`
     * canonical text, not a digest of it. Reuses [pendingBindingMessage] if
     * one was already handed out for this attempt — recomputing with a
     * fresh nonce/`issuedAt` would desync the wallet signature and the
     * later wallet-ack. `null` if not currently recording, or if
     * `walletAddress` isn't valid hex.
     */
    fun beginBinding(walletAddress: String, chainId: Long): String? {
        currentRecordingSession() ?: return null

        val message = pendingBindingMessage ?: run {
            val walletAddressBytes = walletAddress.hexToByteArrayOrNull() ?: return null
            BindingMessage(
                walletAddress = walletAddressBytes,
                ownerPublicKey = sensingCryptography.ownerPublicKey(),
                chainId = chainId,
                nonce = randomSource.randomBytes(16),
                issuedAt = BindingMessage.canonicalIssuedAt(Instant.now()),
            )
        }
        val messageHex = message.walletMessageHex(sensingCryptography) ?: return null
        bindingState = EventBindingState.Connecting
        pendingBindingMessage = message
        return messageHex
    }

    /** Called once the wallet request has been dispatched — moves the ambient status from "connecting" to "waiting on the wallet". No-op if a decline/failure already raced it. */
    fun markBindingAwaitingApproval() {
        if (bindingState != EventBindingState.Connecting) return
        bindingState = EventBindingState.AwaitingApproval
    }

    /**
     * Completes the round trip: has the owner key countersign a
     * `barnard-wallet-ack:v1` message referencing the wallet's own
     * signature bytes, builds and persists the [BindingRecord], and moves
     * to [EventBindingState.Bound]. `null` (no state change) if there is no
     * in-flight attempt to complete, or `walletSignatureHex` isn't valid
     * hex.
     */
    fun completeBinding(walletAddress: String, walletSignatureHex: String): BindingRecord? {
        val message = pendingBindingMessage ?: return null
        val proofId = activeProofId ?: return null
        val event = currentRecordingSession() ?: return null
        val walletSignatureBytes = walletSignatureHex.hexToByteArrayOrNull() ?: return null
        val ackSignature = sensingCryptography.signWalletAcknowledgement(message.walletAddress, walletSignatureBytes)
            ?: return null

        val record = BindingRecord(
            proofId = proofId,
            eventCode = event.eventCode,
            walletAddress = walletAddress,
            eventSigningPublicKey = sensingCryptography.eventSigningPublicKey(event.eventCode),
            ownerPublicKey = message.ownerPublicKey,
            chainId = message.chainId,
            nonce = message.nonce,
            issuedAt = message.issuedAt,
            walletSignatureHex = walletSignatureHex,
            deviceSignature = ackSignature,
        )
        bindingRecordStore.add(record)
        onProofSignatureStateChanged?.invoke(proofId, selfProofRecordStore.recordForProofId(proofId) != null, true)
        bindingState = EventBindingState.Bound(record)
        pendingBindingMessage = null
        return record
    }

    /** The wallet declined, or a transport/timeout error occurred. Distinct from [declineBinding]: this is the round trip failing, not the user dismissing the attempt before starting one. */
    fun failBinding(reason: String) {
        pendingBindingMessage = null
        bindingState = EventBindingState.Failed(reason)
    }

    /**
     * The user backed out of an in-flight attempt without completing a
     * binding — wallet is optional, so this only resets [bindingState],
     * never [scanPhase]; recording keeps running untouched.
     */
    fun declineBinding() {
        pendingBindingMessage = null
        bindingState = currentRecordingSession()?.let { EventBindingState.PendingConnect(it) }
            ?: EventBindingState.None
    }

    override fun openAppSettings() = engine.openAppSettings()

    override fun requestBluetoothPermission(onComplete: () -> Unit) {
        if (disposed) return
        engine.requestPermissions { result ->
            if (disposed) return@requestPermissions
            if (result is BarnardPermissionResult.Granted && result.status.canScan) {
                startNearbyEventDiscoveryIfIdle()
            }
            onComplete()
        }
    }

    override fun startNearbyEventDiscovery() = startNearbyEventDiscoveryIfIdle()

    private fun startNearbyEventDiscoveryIfIdle() {
        if (disposed || scanPhase != ScanPhase.Idle || discoveryOnlyScanOwned) return
        val engineState = engine.getState()
        if (engineState.isScanning || engineState.isAdvertising) return
        engine.startScan()
        discoveryOnlyScanOwned = true
    }

    fun stopNearbyEventDiscovery() {
        val isAdvertising = !disposed && engine.getState().isAdvertising
        val shouldStopScan = discoveryOnlyScanOwned &&
            scanPhase == ScanPhase.Idle &&
            !disposed &&
            !isAdvertising
        discoveryOnlyScanOwned = false
        nearbyDiscovery.reset()
        if (shouldStopScan) engine.stopScan()
    }

    fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean =
        !disposed && engine.onRequestPermissionsResult(requestCode, permissions, grantResults)

    /**
     * Releases Activity-owned transport resources. This is not an ENIN or
     * session boundary: configuration destruction must not create, sign, or
     * close a durable observation window. [leaveEvent] and an observed ENIN
     * rollover are the business boundaries for [windowAccumulator].
     */
    fun dispose() {
        if (disposed) return
        disposed = true
        observationContextRequestOwner = null
        finalizeSelfProofIfNeeded()
        stopParticipantRelay()
        discoveryOnlyScanOwned = false
        nearbyDiscovery.dispose()
        scanPhase = applyStopSensing()
        resetSessionState()
        engine.onEvent = null
        engine.dispose()
    }

    private companion object {
        /** Mirrors iOS's `SensingCoordinator.handleDetection`'s `"Unknown Event"` fallback. */
        const val UNKNOWN_EVENT_CODE = "Unknown Event"

        /**
         * Spec 134's `T`, taken from barnard rather than restated, so the two
         * cannot drift. barnard self-ticks as well, so this cadence is
         * belt-and-braces rather than the only thing keeping a lease honest.
         */
        val RELAY_DECISION_BOUNDARY_MILLIS = BarnardEngine.RELAY_DECISION_BOUNDARY_MS
    }
}

private val ProcessWindowObservationRuntimeOwner = WindowObservationRuntimeOwner()
