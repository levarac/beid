package org.levarac.parallax.registry

private const val EVENT_ID_BYTES: Int = 32
private const val EVENT_CODE_HASH_BYTES: Int = 8

/** Canonical open-event join code: lowercase hex of the complete 32-byte Event ID. */
public fun canonicalOpenCodeV1(eventId: ByteArray): String {
    require(eventId.size == EVENT_ID_BYTES) { "event ID must be exactly 32 bytes" }
    return buildString(EVENT_ID_BYTES * 2) {
        for (byte in eventId) {
            val value = byte.toInt() and 0xff
            append("0123456789abcdef"[value ushr 4])
            append("0123456789abcdef"[value and 0x0f])
        }
    }
}

/** First eight bytes of SHA-256 over the canonical open-code UTF-8 text. */
public fun eventCodeHashForOpenEventV1(eventId: ByteArray): ByteArray =
    Sha256.digest(canonicalOpenCodeV1(eventId).encodeToByteArray())
        .copyOfRange(0, EVENT_CODE_HASH_BYTES)
