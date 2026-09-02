package org.levarac.beid.sensing

import org.levarac.beid.persistence.BindingRecord

/**
 * Wallet connect+binding lifecycle for the currently recording event.
 * Mirrors iOS's `EventBindingState`
 * (`ios/Beid/Sensing/EventBindingState.swift`). Separate from [ScanPhase]
 * because its trigger is decoupled from phase transitions.
 *
 * [EventJoinCoordinator] drives every transition except the wallet-connect
 * SDK negotiation itself — that UI is #124's scope, not this task's; see
 * this task's handoff for what "coordinator-level API, no caller yet" means
 * concretely for [None]/[PendingConnect] here.
 */
sealed class EventBindingState {
    data object None : EventBindingState()
    data class PendingConnect(val session: ScanEventSession) : EventBindingState()
    data object Connecting : EventBindingState()
    data object AwaitingApproval : EventBindingState()
    data class Bound(val record: BindingRecord) : EventBindingState()
    data class Failed(val reason: String) : EventBindingState()
}
