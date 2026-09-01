package org.levarac.beid.sensing

import android.app.Activity
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.levarac.barnard.BarnardEvent
import org.levarac.barnard.BarnardPermissionResult
import org.levarac.parallax.discovery.NearbyEventCandidates
import org.levarac.parallax.registry.RegistryClient
import org.levarac.beid.persistence.BindingRecord
import org.levarac.beid.persistence.BindingRecordStore
import org.levarac.beid.persistence.SelfProofRecord
import org.levarac.beid.persistence.SelfProofRecordStore
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
    nowEpochMillis: () -> Long,
    coroutineScope: CoroutineScope,
    registryClient: RegistryClient? = null,
    private val sensingCryptography: SensingCryptography,
    private val selfProofRecordStore: SelfProofRecordStore,
    private val bindingRecordStore: BindingRecordStore,
    private val randomSource: OwnerKeyRandomSource = SecureRandomOwnerKeySource(),
) : EventJoinSession {
    constructor(activity: Activity) : this(
        engine = BarnardEventJoinEngine(activity),
        nowEpochMillis = System::currentTimeMillis,
        coroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
        registryClient = RegistryDependencies.createClient(),
        sensingCryptography = BarnardSensingCryptography(activity.applicationContext),
        selfProofRecordStore = SelfProofRecordStore(SelfProofRecordStore.defaultFile(activity.filesDir)),
        bindingRecordStore = BindingRecordStore(BindingRecordStore.defaultFile(activity.filesDir)),
    )

    private val accounting = ScanDeviceAccounting()
    private val nearbyDiscovery = NearbyEventDiscoverySession(
        nowEpochMillis = nowEpochMillis,
        coroutineScope = coroutineScope,
        registryClient = registryClient,
    )

    private val _state = MutableStateFlow<EventJoinUiState>(EventJoinUiState.Idle)
    override val state: StateFlow<EventJoinUiState> = _state.asStateFlow()
    val nearbyEventCandidates: StateFlow<NearbyEventCandidates> = nearbyDiscovery.candidates

    /** Source of truth for the current [ScanPhase] — mirrors [_state]'s payload once `Sensing` is reached. */
    private var scanPhase: ScanPhase = ScanPhase.Idle
    private var discoveryOnlyScanOwned = false
    private var disposed = false

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

    init {
        engine.onEvent = ::handleBarnardEvent
    }

    override fun joinEvent(code: String) {
        if (disposed) return
        _state.value = EventJoinUiState.RequestingPermission
        engine.requestPermissions { result ->
            if (disposed) return@requestPermissions
            if (result is BarnardPermissionResult.Granted && result.status.canScan && result.status.canAdvertise) {
                engine.joinEvent(code)
                discoveryOnlyScanOwned = false
                engine.startAuto()
                startSensing()
            } else {
                _state.value = mapPermissionResultToState(result)
            }
        }
    }

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
            is BarnardEvent.Detection -> {
                val detection = event.detection
                handleDetection(
                    enin = detection.enin,
                    rpid = detection.rpid,
                    detectedDisplayId = detection.detectedDisplayId,
                )
            }
            else -> Unit
        }
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
    private fun handleDetection(enin: Long, rpid: String, detectedDisplayId: String?) {
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
        if (previousPhase is ScanPhase.Recording) return
        activeProofId = UUID.randomUUID()
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
        finalizeSelfProofIfNeeded()
        engine.leaveEvent()
        discoveryOnlyScanOwned = false
        nearbyDiscovery.reset()
        scanPhase = applyStopSensing()
        resetSessionState()
        _state.value = EventJoinUiState.Idle
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
        return record
    }

    private fun resetSessionState() {
        accounting.reset()
        activeProofId = null
        bindingState = EventBindingState.None
        pendingBindingMessage = null
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
     * Explicit stop/reset at Activity teardown — mirrors iOS's
     * `endSensing(stopEngine: true)`/`stopSensing()`. A teardown safety
     * net for self-proof, not the primary trigger: [leaveEvent] (the
     * Account screen's real "Leave Event" action) already finalizes and
     * resets per-session state in the common case, so this is idempotent
     * with it via the same [activeProofId] gate.
     */
    fun dispose() {
        if (disposed) return
        disposed = true
        finalizeSelfProofIfNeeded()
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
    }
}
