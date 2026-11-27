package org.levarac.beid.sensing

import java.security.SecureRandom

/**
 * The randomness port for Sigil presence tokens (beid#722; iOS
 * `SigilPresenceTokenSource`, beid#653, `docs/decisions/issue-653-design.md`
 * §1.1). `shared/` never generates a token itself; it assigns the ones
 * supplied here, verbatim, to display ids in first-seen order.
 *
 * A token is random, never derived from a display id, so a stored token says
 * nothing about the peer and the same peer gets an unrelated token in every
 * record. `null` means "no token could be drawn": the caller then assigns
 * nothing, and a record whose peers are not all tokened is never written.
 */
fun interface SigilPresenceTokenSource {
    fun nextToken(): String?
}

/**
 * 16 bytes from [SecureRandom], as 32 lowercase hex characters.
 *
 * A draw that throws returns `null` rather than a zeroed buffer: repeated
 * zero tokens would merge every peer into one. Shared also refuses a
 * duplicate token and fails the record, so a broken source can never draw a
 * wrong Sigil; this makes it fail earlier.
 */
class SecureRandomSigilPresenceTokenSource(
    private val random: SecureRandom = SecureRandom(),
) : SigilPresenceTokenSource {
    override fun nextToken(): String? {
        val bytes = ByteArray(TOKEN_BYTES)
        try {
            random.nextBytes(bytes)
        } catch (_: Exception) {
            return null
        }
        return bytes.joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    private companion object {
        const val TOKEN_BYTES = 16
    }
}
