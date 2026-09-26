package org.levarac.beid.shared.support

import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

public enum class SupportPlatform { IOS, ANDROID }
public enum class SupportState {
    IDLE, SENSING, EVENT_FOUND, RECORDING, SIGNAL_LOST,
    REQUESTING_PERMISSION, VERIFYING_REGISTRY, JOIN_FAILED, OWNER_KEY_UNAVAILABLE, PERMISSION_DENIED,
}
public enum class SupportFailure {
    NONE, NETWORK_REQUIRED, EVENT_NOT_FOUND, CODE_MISMATCH, EVENT_NOT_ACTIVE,
    VERIFICATION_FAILED, UNKNOWN, OWNER_KEY_UNAVAILABLE, PERMISSION_DENIED, SIGNAL_LOST,
}

/** UI reason keys only: an unknown string is discarded, never partially redacted. */
public fun supportFailureForReasonKey(key: String): SupportFailure = when (key) {
    "network_required" -> SupportFailure.NETWORK_REQUIRED
    "event_not_found" -> SupportFailure.EVENT_NOT_FOUND
    "code_mismatch" -> SupportFailure.CODE_MISMATCH
    "event_not_active" -> SupportFailure.EVENT_NOT_ACTIVE
    "verification_failed" -> SupportFailure.VERIFICATION_FAILED
    else -> SupportFailure.UNKNOWN
}

/**
 * C / INVENT, beid#466. Privacy predicate owner: https://github.com/levarac/parallax/issues/74.
 *
 * Only closed enum state/reason pairs enter history. No artifact/store or generic
 * diagnostic object is accepted. Output and retention are shared by both hosts;
 * callers serialize access on their UI thread. The newest 100 changes survive
 * within this process. Timestamps are device time, not an authoritative clock.
 */
public class SupportBundleRecorder {
    private data class Entry(val state: SupportState, val failure: SupportFailure, val timestampMs: Long)
    private val entries = ArrayDeque<Entry>()

    public fun record(state: SupportState, failure: SupportFailure, timestampMs: Long) {
        val previous = entries.lastOrNull()
        if (previous?.state == state && previous.failure == failure) return
        if (entries.size == 100) entries.removeFirst()
        entries.addLast(Entry(state, failure, timestampMs.coerceAtLeast(0)))
    }

    public fun exportJson(platform: SupportPlatform, appVersion: String, build: String, gitHeight: String): String =
        buildJsonObject {
            put("schemaVersion", 1)
            put("platform", platform.name)
            put("appVersion", numericVersion(appVersion))
            put("build", numericVersion(build))
            // The public git ancestry count is a number, never arbitrary text.
            // Missing/local/invalid metadata remains explicitly unknown (null).
            put("gitHeight", if (Regex("[0-9]{1,10}").matches(gitHeight)) gitHeight.toLong() else null)
            put("historyScope", "current_process")
            put("entries", buildJsonArray {
                for (entry in entries) add(buildJsonObject {
                    // One hour is at least as coarse as every supported ENIN duration.
                    put("hourStartEpochMs", entry.timestampMs / 3_600_000 * 3_600_000)
                    put("state", entry.state.name)
                    put("failure", entry.failure.name)
                })
            })
        }.toString()

    private fun numericVersion(value: String): String =
        if (value.length <= 32 && Regex("[0-9]{1,10}(\\.[0-9]{1,10}){0,3}").matches(value)) value else "unknown"
}
