package org.levarac.beid.sensing

import kotlinx.coroutines.flow.StateFlow

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

    fun joinEvent(code: String)

    fun openAppSettings()
}
