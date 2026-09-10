package org.levarac.beid.ui

import org.levarac.beid.BuildConfig

/**
 * The version row's text, shared in shape with iOS (beid#491).
 *
 * Renders `{marketing} ({height}+{store})`, e.g. `1.0.0 (1234+1000000091)`.
 *
 * - `height` is the git height, passed in by CI as `-PgitHeight` and surfaced
 *   through `BuildConfig.GIT_HEIGHT`. It is a function of the built commit's
 *   ancestry, so an Android build and an iOS build showing the same height were
 *   built from the same commit. That is the only thing this number is for.
 * - `store` is `versionCode`, which the delivery lane assigns from the workflow
 *   run. It stays in the row even when the height is absent, because it is the
 *   number Google Play shows.
 *
 * With no `-PgitHeight` the height position reads `local` rather than `0` or an
 * empty string, so a screenshot from a developer build can never be mistaken for
 * a delivered one.
 */
object AppVersion {
    const val LOCAL_HEIGHT_PLACEHOLDER = "local"

    fun displayString(
        marketing: String = BuildConfig.VERSION_NAME,
        store: Int = BuildConfig.VERSION_CODE,
        height: String = BuildConfig.GIT_HEIGHT,
    ): String {
        val resolved = height.ifBlank { LOCAL_HEIGHT_PLACEHOLDER }
        return "$marketing ($resolved+$store)"
    }
}
