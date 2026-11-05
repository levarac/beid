package org.levarac.beid.navigation

import java.util.UUID

/**
 * Navigation destinations — the Compose-Navigation equivalent of iOS's
 * `AppScreen` enum (`ios/Beid/Navigation/AppScreen.swift`). Home combines
 * nearby participation with the participant's collected event groups.
 */
sealed class Screen(val route: String) {
    data object Welcome : Screen("welcome")
    data object BluetoothPermission : Screen("bluetooth_permission")
    data object BluetoothDenied : Screen("bluetooth_denied")
    data object BluetoothOff : Screen("bluetooth_off")
    data object Home : Screen("home")
    /** Compatibility route for restored navigation state targeting the former home. */
    data object EventJoin : Screen("event_join")
    data object Account : Screen("account")
    data object ManualEventCode : Screen("manual_event_code")

    /**
     * Flat, reverse-chronological list of collected proofs (beid#121) — see
     * `RecordsScreen.kt`'s kdoc for the full placement reasoning. Reached
     * the way iOS's secondary `PastEventsView` is reached (from Account).
     */
    data object Records : Screen("records")
    /** An anchor record identifies a group without encoding or inventing event identity. */
    data object EventRecords : Screen("event_records/{anchorId}") {
        const val ANCHOR_ID_ARG: String = "anchorId"
        fun route(anchorId: UUID): String = "event_records/$anchorId"
    }
    data object TodaySummary : Screen("today_summary")

    /**
     * Detail screen for one collected proof (beid#122), reached by tapping a
     * [Records] row. Carries the record's id as a path segment — the first
     * parameterized route in this file — rather than passing the whole
     * [org.levarac.beid.persistence.ProofRecord] through the nav graph, so
     * the destination always re-reads current store state instead of a
     * stale snapshot captured at navigation time.
     */
    data object RecordDetail : Screen("records/{recordId}") {
        const val RECORD_ID_ARG: String = "recordId"

        fun route(recordId: UUID): String = "records/$recordId"
    }
}
