package org.levarac.beid.navigation

/**
 * A visible, uninterrupted empty-discovery interval, measured by uptime.
 * Native port of iOS `HomeStandbyState` (`ios/Beid/Navigation/HomeStandbyState.swift`,
 * PR #795). This is presentation timing; event eligibility remains in shared code.
 *
 * Times are uptime milliseconds (`SystemClock.uptimeMillis()` in production),
 * never wall-clock time, so a clock change cannot shorten or extend the wait.
 */
data class HomeStandbyState(val listeningStartedAtMillis: Long? = null) {
    /**
     * Starts the interval the first time Now is enabled with nothing to join
     * and keeps it through repeated updates; any disabled update, or one with
     * a joinable candidate, discards it, so the next interval is timed from
     * scratch. Only a joinable candidate ends the wait: a nearby event whose
     * JOIN is disabled leaves nothing to tap, so it does not (iOS
     * `update(isEnabled:hasJoinableCandidates:now:)`).
     */
    fun update(isEnabled: Boolean, hasJoinableCandidates: Boolean, nowMillis: Long): HomeStandbyState {
        if (!isEnabled || hasJoinableCandidates) return HomeStandbyState()
        return if (listeningStartedAtMillis == null) HomeStandbyState(nowMillis) else this
    }

    fun elapsedMillis(atMillis: Long): Long {
        val startedAt = listeningStartedAtMillis ?: return 0L
        return maxOf(0L, atMillis - startedAt)
    }

    fun offersCodeEntry(atMillis: Long): Boolean =
        listeningStartedAtMillis != null && elapsedMillis(atMillis) >= CODE_ENTRY_DELAY_MILLIS

    companion object {
        /** iOS `offersCodeEntry(at:)`'s 30-second boundary. */
        const val CODE_ENTRY_DELAY_MILLIS: Long = 30_000L
    }
}

/** The two Home tabs, as iOS `HomeTab`. */
enum class HomeTab { Now, Records }
