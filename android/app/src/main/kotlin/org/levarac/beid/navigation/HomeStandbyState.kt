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
     * Starts the interval the first time Now is enabled with no candidate and
     * keeps it through repeated updates; any disabled or non-empty update
     * discards it, so the next interval is timed from scratch.
     */
    fun update(isEnabled: Boolean, hasCandidates: Boolean, nowMillis: Long): HomeStandbyState {
        if (!isEnabled || hasCandidates) return HomeStandbyState()
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
