package org.levarac.beid.navigation

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
}
