package org.levarac.beid.ui.screens

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import org.levarac.beid.sensing.EventJoinSession
import org.levarac.beid.sensing.EventJoinUiState
import org.levarac.beid.shared.event.EventJoinFailureReason
import org.levarac.beid.shared.event.NearbyEventSearchOutcome
import org.levarac.beid.shared.event.normalizedEventCodeOrNull

/**
 * Field-level validation error shown inline under the event-code field,
 * mirroring iOS's `EventCodeEntryView.errorMessage` (`ios/Beid/Views/
 * EventCodeEntryView.swift`) — same copy, same "clear on edit" behavior.
 *
 * [JoinFailed] is produced as of beid#463, from
 * [EventJoinUiState.JoinFailed]'s reason. Before it, this class carried a note
 * saying the case had no producer because the session collapsed every
 * non-permission outcome together — which is precisely the gap acceptance
 * condition 3 names: a participant who cannot reach the network has to be told
 * that, and a screen that renders nothing at all cannot tell them anything.
 */
sealed class EventJoinFieldError {
    data object EmptyCode : EventJoinFieldError()

    /** A join that was attempted and refused. [reason] is decided in `shared/`, the copy for it is not. */
    data class JoinFailed(val reason: EventJoinFailureReason) : EventJoinFieldError()
}

/** Everything [org.levarac.beid.ui.screens.EventJoinScreen] needs to render, combined into one flow. */
data class EventJoinScreenState(
    val eventCode: String = "",
    val fieldError: EventJoinFieldError? = null,
    val sessionState: EventJoinUiState = EventJoinUiState.Idle,
    val nearbyEventCards: List<org.levarac.beid.sensing.NearbyEventCard> = emptyList(),
    val selectedNearbyEventHashHex: String? = null,
    val searchOutcome: NearbyEventSearchOutcome = NearbyEventSearchOutcome.SEARCHING,
)

/**
 * Presentation layer over [EventJoinSession] — owns the event-code text
 * field and its validation state, and forwards the actual join decision to
 * [session]. This is a thin layer, not a second decision-maker: what counts
 * as empty and what the canonical form is come from
 * `org.levarac.beid.shared.event.normalizedEventCodeOrNull` (beid#226,
 * DECISIONS 2026-08-20), the same `shared/` decision iOS's join path
 * applies, not a native `isBlank()`/trim/lowercase check owned here.
 */
class EventJoinViewModel(private val session: EventJoinSession) : ViewModel() {
    private val _uiState = MutableStateFlow(EventJoinScreenState(sessionState = session.state.value))
    val uiState: StateFlow<EventJoinScreenState> = _uiState.asStateFlow()

    init {
        viewModelScope.launch {
            session.state.collect { sessionState ->
                _uiState.update {
                    it.copy(
                        sessionState = sessionState,
                        // A refusal is surfaced under the field, where the code
                        // that caused it is still on screen and still editable.
                        // Any other state clears it: leaving the error visible
                        // through the next attempt would attach last attempt's
                        // explanation to this attempt's code.
                        fieldError = (sessionState as? EventJoinUiState.JoinFailed)
                            ?.let { failed -> EventJoinFieldError.JoinFailed(failed.reason) },
                    )
                }
            }
        }
        viewModelScope.launch {
            session.nearbyEventSearchOutcome.collect { outcome ->
                _uiState.update { it.copy(searchOutcome = outcome) }
            }
        }
        viewModelScope.launch {
            session.nearbyEventCards.collect { cards ->
                _uiState.update {
                    val joinableCards = cards.filter { card -> card.eventIdHex != null }
                    val selectedHash = when {
                        joinableCards.isEmpty() -> null
                        joinableCards.any { card -> card.eventCodeHashHex == it.selectedNearbyEventHashHex } ->
                            it.selectedNearbyEventHashHex
                        joinableCards.size == 1 -> joinableCards.single().eventCodeHashHex
                        else -> null
                    }
                    it.copy(
                        nearbyEventCards = cards,
                        selectedNearbyEventHashHex = selectedHash,
                    )
                }
            }
        }
    }

    fun onEventCodeChanged(code: String) {
        _uiState.update { it.copy(eventCode = code, fieldError = null) }
    }

    /**
     * Fills the field from the clipboard in one action (beid#463).
     *
     * A separate entry point from [onEventCodeChanged] rather than a call into
     * it, because the thing that has to be true here is not "the field ends up
     * holding this text" but "the participant never typed it". A canonical
     * open code is 64 hex characters; the issue rules out hand-entering one as
     * a route that does not exist in practice, and a paste that went through
     * the per-keystroke path would be indistinguishable in a test from someone
     * typing it, which is exactly the claim acceptance condition 2 makes.
     *
     * Blank clipboard content is ignored rather than clearing the field: a
     * mis-tap on paste with an empty clipboard should not destroy a code the
     * participant already has in front of them.
     */
    fun onEventCodePasted(clipboardText: String?) {
        val pasted = clipboardText?.takeIf { it.isNotBlank() } ?: return
        _uiState.update { it.copy(eventCode = pasted, fieldError = null) }
    }

    fun submit() {
        val code = _uiState.value.eventCode
        val normalized = normalizedEventCodeOrNull(code)
        if (normalized == null) {
            _uiState.update { it.copy(fieldError = EventJoinFieldError.EmptyCode) }
            return
        }
        _uiState.update { it.copy(fieldError = null) }
        session.joinEvent(normalized)
    }

    fun openAppSettings() = session.openAppSettings()

    /**
     * Forwards the tapped card's stable hash, not the Event ID it was
     * rendering (beid#374). The lookup below is presentation only — it decides
     * what to select in the list — and the session re-reads the current
     * candidate itself. Whether this event may actually be joined is decided
     * there and in `shared/`, never by what this list happened to show.
     */
    fun joinNearbyEvent(eventCodeHashHex: String) {
        _uiState.value.nearbyEventCards
            .firstOrNull { it.eventCodeHashHex == eventCodeHashHex }
            ?: return
        _uiState.update { it.copy(selectedNearbyEventHashHex = eventCodeHashHex) }
        session.joinNearbyEvent(eventCodeHashHex)
    }

    fun simulateSignalLost() = session.simulateSignalLost()

    fun resumeSensing() = session.resumeSensing()

    /** See [EventJoinSession.recordingCeremonyShown]. */
    val recordingCeremonyShown: Boolean get() = session.recordingCeremonyShown

    fun markRecordingCeremonyShown() = session.markRecordingCeremonyShown()

    class Factory(private val session: EventJoinSession) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T = EventJoinViewModel(session) as T
    }
}
