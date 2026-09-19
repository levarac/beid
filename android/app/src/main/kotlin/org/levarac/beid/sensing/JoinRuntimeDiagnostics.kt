package org.levarac.beid.sensing

import org.levarac.beid.BuildConfig

/** Emits the privacy-bounded, testable line format for the native join path. */
internal fun emitJoinStageDiagnostic(
    log: (String) -> Unit,
    eventIdHex: String?,
    stage: String,
    outcome: String,
    attempt: Int? = null,
    retryAtEpochMillis: Long? = null,
) {
    if (!BuildConfig.DEBUG) return
    log(
        "join_stage event_id=${diagnosticEventIdPrefix(eventIdHex)} " +
            "stage=$stage outcome=$outcome " +
            "attempt=${attempt ?: "none"} " +
            "retry_at_epoch_ms=${retryAtEpochMillis ?: "none"}",
    )
}

private fun diagnosticEventIdPrefix(eventIdHex: String?): String {
    val normalized = eventIdHex?.removePrefix("0x")?.lowercase()
    return if (normalized != null && normalized.length == 64 && normalized.all { it in '0'..'9' || it in 'a'..'f' }) {
        normalized.take(8)
    } else {
        "unknown"
    }
}
