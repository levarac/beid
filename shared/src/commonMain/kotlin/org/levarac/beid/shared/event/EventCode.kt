package org.levarac.beid.shared.event

/**
 * Canonical form of a user-entered event code (beid#226, DECISIONS
 * 2026-08-20): surrounding whitespace trimmed, then case folded. Returns
 * null if nothing remains after trimming — an event code cannot canonicalize
 * to empty.
 *
 * Uses the locale-invariant `lowercase()` (no Locale argument), not
 * device-locale-sensitive casing — a Turkish-locale device folding "I" to
 * "ı" instead of "i" would silently desync two devices' derived RPID for
 * the exact same typed text, which is the one thing this function exists to
 * prevent.
 *
 * Deliberately excludes Unicode normalization (NFKC etc.) and full-width/
 * half-width folding — out of scope by product decision (DECISIONS
 * 2026-08-20). Do not add them here without a new decision recorded.
 */
public fun normalizedEventCodeOrNull(rawEventCode: String): String? {
    val trimmed = rawEventCode.trim()
    if (trimmed.isEmpty()) return null
    return trimmed.lowercase()
}
