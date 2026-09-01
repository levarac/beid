package org.levarac.beid.sensing

import java.security.MessageDigest

/**
 * `eventIdHash` input to the self-proof message
 * (`docs/specs/barnard-binding-conformance.md` §2.2) — Barnard requires a
 * 32-byte digest; beid's `eventCode` is a `String`. Barnard's own spec does
 * not mandate a specific mapping, only that the input is 32 bytes; this
 * follows the spec document's own recommendation, `SHA256(UTF8(eventCode))`
 * — the same rule `ios/Beid/Sensing/EventIdHash.swift` uses, so both
 * platforms derive the same 32-byte value from the same event code.
 */
object EventIdHash {
    fun compute(eventCode: String): ByteArray =
        MessageDigest.getInstance("SHA-256").digest(eventCode.toByteArray(Charsets.UTF_8))
}
