package org.levarac.beid.shared.sensing

/**
 * Whether [enin] crosses a co-presence window boundary relative to
 * [lastEnin] — i.e. whether the caller must clear its co-presence set
 * before inserting and counting this detection's rpid. A `null` [lastEnin]
 * (no window observed yet) always counts as crossing.
 *
 * Mirrors the rule iOS and Android each independently encoded before
 * beid#231: both cleared their co-presence set before inserting, on ENIN
 * change. A lingering device's rotated rpid from a previous window must
 * never still be counted in the new one.
 */
public fun coPresenceWindowBoundaryCrossed(lastEnin: Long?, enin: Long): Boolean =
    lastEnin != enin

/**
 * Canonical form of a detected display id for device-identity comparison.
 * Barnard emits lowercase hex today; this normalizes defensively so a
 * future upstream case change cannot split one device into two. `null`
 * passes through unchanged (Barnard B003 unavailable) — never falls back
 * to another identifier.
 *
 * Uses the locale-invariant `lowercase()` (no Locale argument), not
 * device-locale-sensitive casing — the same reasoning beid#226's
 * `normalizedEventCodeOrNull` uses.
 */
public fun normalizedDisplayIdOrNull(detectedDisplayId: String?): String? =
    detectedDisplayId?.lowercase()
