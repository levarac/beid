package org.levarac.beid

import android.content.Intent
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class MainActivityScenarioTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    @Test
    fun debugLaunchExtraStartsWithoutConstructingTheRealCoordinatorOrRegistryClient() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val intent = Intent(context, MainActivity::class.java)
            .putExtra(MainActivity.DEMO_SCENARIO_EXTRA, "crowdSurge")

        val activity = Robolectric.buildActivity(MainActivity::class.java, intent).setup().get()

        assertNull(
            MainActivity::class.java.getDeclaredField("eventJoinCoordinator")
                .apply { isAccessible = true }
                .get(activity),
        )
        assertNull(MainActivity::class.java.getDeclaredField("registryClient").apply { isAccessible = true }.get(activity))
    }

    @Test
    fun debugScenarioLaunchMakesRecordsReachableWithoutConstructingRealDependencies() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val intent = Intent(context, MainActivity::class.java)
            .putExtra(MainActivity.DEMO_SCENARIO_EXTRA, "longDisplayNames")
            .putExtra(MainActivity.DEMO_SCENARIO_SURFACE_EXTRA, "records")

        val activity = Robolectric.buildActivity(MainActivity::class.java, intent).setup().get()

        composeTestRule.onNodeWithText(
            "The International Gathering for Open, Verifiable and Durable Local Participation 🌏",
        ).assertIsDisplayed()
        assertNull(
            MainActivity::class.java.getDeclaredField("eventJoinCoordinator")
                .apply { isAccessible = true }
                .get(activity),
        )
        assertNull(MainActivity::class.java.getDeclaredField("registryClient").apply { isAccessible = true }.get(activity))
    }
}
