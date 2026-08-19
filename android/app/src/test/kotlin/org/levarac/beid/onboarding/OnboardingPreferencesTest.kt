package org.levarac.beid.onboarding

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class OnboardingPreferencesTest {
    @Test
    fun defaultsToFalseOnFirstRead() {
        val context = ApplicationProvider.getApplicationContext<Context>()

        assertFalse(OnboardingPreferences(context).hasCompletedOnboarding)
    }

    @Test
    fun roundTripsTrueAndFalse() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val prefs = OnboardingPreferences(context)

        prefs.hasCompletedOnboarding = true
        assertTrue(OnboardingPreferences(context).hasCompletedOnboarding)

        prefs.hasCompletedOnboarding = false
        assertFalse(OnboardingPreferences(context).hasCompletedOnboarding)
    }
}
