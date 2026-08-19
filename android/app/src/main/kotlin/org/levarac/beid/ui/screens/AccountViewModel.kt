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

/** Everything [org.levarac.beid.ui.screens.AccountScreen] needs to render, combined into one flow. */
data class AccountScreenState(
    val sessionState: EventJoinUiState = EventJoinUiState.Idle,
)

/**
 * Presentation layer over [EventJoinSession] for the Account screen (beid#126)
 * — same thin-layer shape as [EventJoinViewModel]: it makes no product
 * decisions of its own, only forwards [leaveEvent] to [session] and republishes
 * [EventJoinSession.state].
 */
class AccountViewModel(private val session: EventJoinSession) : ViewModel() {
    private val _uiState = MutableStateFlow(AccountScreenState(sessionState = session.state.value))
    val uiState: StateFlow<AccountScreenState> = _uiState.asStateFlow()

    init {
        viewModelScope.launch {
            session.state.collect { sessionState ->
                _uiState.update { it.copy(sessionState = sessionState) }
            }
        }
    }

    fun leaveEvent() = session.leaveEvent()

    class Factory(private val session: EventJoinSession) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T = AccountViewModel(session) as T
    }
}
