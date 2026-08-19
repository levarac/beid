package org.levarac.beid.navigation

import androidx.compose.runtime.Composable
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import org.levarac.beid.sensing.EventJoinSession
import org.levarac.beid.ui.screens.EventJoinRoute

/**
 * Root navigation scaffold — the Compose-Navigation equivalent of iOS's
 * `RootView` + `AppCoordinator`. A single-activity app hosts this once;
 * screens are added as routes here as they land.
 */
@Composable
fun AppNavHost(session: EventJoinSession) {
    val navController = rememberNavController()
    NavHost(navController = navController, startDestination = Screen.EventJoin.route) {
        composable(Screen.EventJoin.route) {
            EventJoinRoute(session)
        }
    }
}
