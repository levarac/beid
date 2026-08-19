package org.levarac.beid.onboarding

import android.content.Context

/**
 * Persisted "has completed onboarding" flag — the Android counterpart of
 * iOS's `UserDefaults.standard.bool(forKey: "beid.hasCompletedOnboarding")`
 * (`AppCoordinator.hasCompletedOnboardingKey`). Defaults to `false` until
 * ever set.
 */
class OnboardingPreferences(context: Context) {
    private val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    var hasCompletedOnboarding: Boolean
        get() = prefs.getBoolean(KEY_HAS_COMPLETED_ONBOARDING, false)
        set(value) = prefs.edit().putBoolean(KEY_HAS_COMPLETED_ONBOARDING, value).apply()

    private companion object {
        const val PREFS_NAME = "beid_onboarding"
        const val KEY_HAS_COMPLETED_ONBOARDING = "has_completed_onboarding"
    }
}
