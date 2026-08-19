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
)

/**
 * Presentation layer over [EventJoinSession] — owns the event-code text
 * field and its validation state, and forwards the actual join decision to
 * [session] unchanged. This is a thin layer, not a second decision-maker:
 * the only decision made here is "is the code field blank?", a
 * presentation-only check, not a product/session decision.
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
    }

    fun onEventCodeChanged(code: String) {
        _uiState.update { it.copy(eventCode = code, fieldError = null) }
    }

    fun submit() {
        val code = _uiState.value.eventCode
        if (code.isBlank()) {
            _uiState.update { it.copy(fieldError = EventJoinFieldError.EmptyCode) }
            return
        }
        _uiState.update { it.copy(fieldError = null) }
        session.joinEvent(code)
    }

    fun openAppSettings() = session.openAppSettings()

    fun simulateSignalLost() = session.simulateSignalLost()

    fun resumeSensing() = session.resumeSensing()

    class Factory(private val session: EventJoinSession) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T = EventJoinViewModel(session) as T
    }
}
