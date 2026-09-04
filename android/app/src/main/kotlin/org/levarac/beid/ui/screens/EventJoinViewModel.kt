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
import org.levarac.beid.shared.event.normalizedEventCodeOrNull

/**
 * Field-level validation error shown inline under the event-code field,
 * mirroring iOS's `EventCodeEntryView.errorMessage` (`ios/Beid/Views/
 * EventCodeEntryView.swift`) — same copy, same "clear on edit" behavior.
 *
 * [JoinFailed] has no producer yet: [EventJoinSession]'s underlying state
 * machine ([EventJoinUiState]) collapses every non-permission join outcome
 * into [EventJoinUiState.PermissionDenied] — it doesn't yet distinguish "the
 * SDK rejected this code" from "permission was denied". Wiring this branch
 * is a coordinator change, out of this ViewModel's scope — the case is kept
 * here, sharing the same rendering path as [EmptyCode], so the future wiring
 * is a one-line state change rather than new UI.
 */
sealed class EventJoinFieldError {
    data object EmptyCode : EventJoinFieldError()
    data object JoinFailed : EventJoinFieldError()
}

/** Everything [org.levarac.beid.ui.screens.EventJoinScreen] needs to render, combined into one flow. */
data class EventJoinScreenState(
    val eventCode: String = "",
    val fieldError: EventJoinFieldError? = null,
    val sessionState: EventJoinUiState = EventJoinUiState.Idle,
    val nearbyEventCards: List<org.levarac.beid.sensing.NearbyEventCard> = emptyList(),
    val selectedNearbyEventHashHex: String? = null,
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
                _uiState.update { it.copy(sessionState = sessionState) }
            }
        }
        viewModelScope.launch {
            session.nearbyEventCards.collect { cards ->
                _uiState.update {
                    val selectedHash = when {
                        cards.isEmpty() -> null
                        it.nearbyEventCards.isEmpty() -> cards.first().eventCodeHashHex
                        cards.any { card -> card.eventCodeHashHex == it.selectedNearbyEventHashHex } ->
                            it.selectedNearbyEventHashHex
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

    fun joinNearbyEvent(eventCodeHashHex: String) {
        val card = _uiState.value.nearbyEventCards
            .firstOrNull { it.eventCodeHashHex == eventCodeHashHex }
            ?: return
        _uiState.update { it.copy(selectedNearbyEventHashHex = eventCodeHashHex) }
        card.eventIdHex?.let(session::joinNearbyEvent)
    }

    fun simulateSignalLost() = session.simulateSignalLost()

    fun resumeSensing() = session.resumeSensing()

    class Factory(private val session: EventJoinSession) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T = EventJoinViewModel(session) as T
    }
}
