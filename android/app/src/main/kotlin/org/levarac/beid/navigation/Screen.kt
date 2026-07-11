package org.levarac.beid.navigation

/**
 * Navigation destinations — the Compose-Navigation equivalent of iOS's
 * `AppScreen` enum (`ios/Beid/Navigation/AppScreen.swift`). This scaffold
 * only wires up [EventJoin]; further screens (sensing, proof collection,
 * etc.) land in follow-up slices as their iOS counterparts stabilize.
 */
sealed class Screen(val route: String) {
    data object EventJoin : Screen("event_join")
}
