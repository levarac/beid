package org.levarac.beid.ui.screens

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.levarac.beid.sensing.EventJoinSession
import org.levarac.beid.sensing.EventJoinUiState

/** Shared test double for [EventJoinSession] — no real `Activity`/`BarnardEngine` involved. */
internal class FakeEventJoinSession(initial: EventJoinUiState = EventJoinUiState.Idle) : EventJoinSession {
    private val mutableState = MutableStateFlow(initial)
    override val state: StateFlow<EventJoinUiState> = mutableState.asStateFlow()

    var joinedCode: String? = null
        private set
    var openedAppSettings: Boolean = false
        private set

    override fun joinEvent(code: String) {
        joinedCode = code
    }

    override fun openAppSettings() {
        openedAppSettings = true
    }

    fun emit(next: EventJoinUiState) {
        mutableState.value = next
    }
}
