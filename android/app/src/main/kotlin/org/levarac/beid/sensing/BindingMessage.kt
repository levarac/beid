package org.levarac.beid.sensing

import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

/**
 * Canonical content of the wallet `personal_sign` step in the wallet
 * connect+binding round trip — the literal `barnard-account-binding:v1`
 * text a Barnard-conformant verifier expects
 * (`docs/specs/barnard-binding-conformance.md` §2.3), built via
 * [SensingCryptography.buildAccountBindingText]. Mirrors iOS's
 * `BindingMessage` (`ios/Beid/Sensing/BindingMessage.swift`).
 *
 * Fixed once per binding attempt and reused across both the wallet
 * signature and the later owner-key wallet-ack, so both reference the
 * identical `nonce`/`issuedAt` — recomputing either between the two steps
 * would desync them.
 */
data class BindingMessage(
    val walletAddress: ByteArray,
    val ownerPublicKey: ByteArray,
    val chainId: Long,
    val nonce: ByteArray,
    /** RFC 3339 UTC, second precision (`YYYY-MM-DDTHH:MM:SSZ`) — see [canonicalIssuedAt]. */
    val issuedAt: String,
) {
    /**
     * The literal canonical text, or `null` if any field fails Barnard's
     * own shape validation.
     */
    fun canonicalText(cryptography: SensingCryptography): String? =
        cryptography.buildAccountBindingText(
            domain = DOMAIN,
            walletAddress = walletAddress,
            ownerPublicKey = ownerPublicKey,
            chainId = chainId,
            nonce = nonce,
            issuedAt = issuedAt,
        )

    /**
     * What the wallet's `personal_sign` actually signs: `0x`-prefixed hex of
     * the canonical text's UTF-8 bytes (not a digest of it).
     */
    fun walletMessageHex(cryptography: SensingCryptography): String? =
        canonicalText(cryptography)?.let { "0x" + it.toByteArray(Charsets.UTF_8).toLowercaseHex() }

    override fun equals(other: Any?): Boolean =
        other is BindingMessage &&
            walletAddress.contentEquals(other.walletAddress) &&
            ownerPublicKey.contentEquals(other.ownerPublicKey) &&
            chainId == other.chainId &&
            nonce.contentEquals(other.nonce) &&
            issuedAt == other.issuedAt

    override fun hashCode(): Int {
        var result = walletAddress.contentHashCode()
        result = 31 * result + ownerPublicKey.contentHashCode()
        result = 31 * result + chainId.hashCode()
        result = 31 * result + nonce.contentHashCode()
        result = 31 * result + issuedAt.hashCode()
        return result
    }

    companion object {
        /**
         * Resolved 2026-08-03 (decision 6.a): the literal example domain
         * from Barnard's own worked example and pinned test vector — not a
         * domain beid currently serves or proves ownership of. Matches
         * iOS's `BindingMessage.domain`.
         */
        const val DOMAIN = "beid.levarac.org"

        private val ISSUED_AT_FORMATTER: DateTimeFormatter =
            DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'").withZone(ZoneOffset.UTC)

        /**
         * Formats [instant] as the RFC 3339 UTC second-precision string
         * Barnard's own validation requires (`YYYY-MM-DDTHH:MM:SSZ`, no
         * fractional seconds, literal `Z`).
         */
        fun canonicalIssuedAt(instant: Instant): String = ISSUED_AT_FORMATTER.format(instant)
    }
}
