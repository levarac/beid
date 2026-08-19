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
}
