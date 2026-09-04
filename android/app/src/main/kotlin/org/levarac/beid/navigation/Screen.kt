package org.levarac.beid.navigation

import java.util.UUID

/**
 * Navigation destinations — the Compose-Navigation equivalent of iOS's
 * `AppScreen` enum (`ios/Beid/Navigation/AppScreen.swift`). [EventJoin]
 * stands in for iOS's `.home`, since Android has no post-onboarding
 * collection-home screen yet (android/README.md); further screens land in
 * follow-up slices as their iOS counterparts stabilize.
 */
sealed class Screen(val route: String) {
    data object Welcome : Screen("welcome")
    data object BluetoothPermission : Screen("bluetooth_permission")
    data object BluetoothOff : Screen("bluetooth_off")
    data object EventJoin : Screen("event_join")
    data object Account : Screen("account")
    data object ManualEventCode : Screen("manual_event_code")

    /**
     * Flat, reverse-chronological list of collected proofs (beid#121) — see
     * `RecordsScreen.kt`'s kdoc for the full placement reasoning. Reached
     * the way iOS's *secondary* `PastEventsView` is reached (from Account),
     * not the way its *primary* `CollectionHomeView` is — this is a
     * deliberate, stated divergence, not this screen standing in for
     * [EventJoin]'s eventual promotion to a real collection home (a
     * separate navigation decision belonging to #141).
     */
    data object Records : Screen("records")
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
