package org.levarac.beid.venue

import android.content.ComponentName
import androidx.test.core.app.ApplicationProvider
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class VenueActivityTest {
    @Test
    fun launcherIntentIsExplicitAndCarriesNoAutomaticInput() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val intent = VenueActivity.createIntent(context)

        assertEquals(ComponentName(context, VenueActivity::class.java), intent.component)
        assertNull(intent.data)
        assertNull(intent.extras)
    }
}
