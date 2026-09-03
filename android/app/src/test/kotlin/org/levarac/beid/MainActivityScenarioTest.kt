package org.levarac.beid

import android.content.Intent
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class MainActivityScenarioTest {
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
}
