package org.levarac.beid.shared.sensing

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * RED evidence for beid#231 items 1 and 2: this vector table pins the two
 * device-counting rules iOS and Android each independently encoded before
 * this issue — window-boundary co-presence clearing, and displayId
 * lowercase normalization. `coPresenceWindowBoundaryCrossed` and
 * `normalizedDisplayIdOrNull` do not exist yet, so this file fails to
 * compile — that is the licensing failure Step 2 of
 * docs/kmp-shared-foundation.md requires before implementation begins.
 *
 * Oracle: the current, already-agreed native behavior on both platforms
 * (class A/SWAP per beid#231's task breakdown, not a B/CONVERGE ruling —
 * unlike beid#226/PR #243, iOS and Android do not disagree here today).
 */
class DeviceAccountingTest {

    // MARK: - coPresenceWindowBoundaryCrossed

    @Test
    fun noPriorWindowAlwaysCountsAsCrossed() {
        assertTrue(coPresenceWindowBoundaryCrossed(lastEnin = null, enin = 1))
    }

    @Test
    fun sameEninAsLastSeenIsNotCrossed() {
        assertFalse(coPresenceWindowBoundaryCrossed(lastEnin = 1, enin = 1))
    }

    @Test
    fun differentEninFromLastSeenIsCrossed() {
        assertTrue(coPresenceWindowBoundaryCrossed(lastEnin = 1, enin = 2))
    }

    @Test
    fun movingBackToAnEarlierEninIsStillCrossed() {
        // The rule is plain (in)equality, not monotonic-time reasoning — a
        // caller that somehow re-observes an earlier enin must still treat
        // it as a boundary crossing relative to the last-seen value.
        assertTrue(coPresenceWindowBoundaryCrossed(lastEnin = 5, enin = 2))
    }

    @Test
    fun zeroEninIsNotSpecialCased() {
        assertFalse(coPresenceWindowBoundaryCrossed(lastEnin = 0, enin = 0))
        assertTrue(coPresenceWindowBoundaryCrossed(lastEnin = null, enin = 0))
    }

    // MARK: - normalizedDisplayIdOrNull

    @Test
    fun nullPassesThroughUnchanged() {
        assertNull(normalizedDisplayIdOrNull(null))
    }

    @Test
    fun alreadyLowercaseIsUnchanged() {
        assertEquals("abcd", normalizedDisplayIdOrNull("abcd"))
    }

    @Test
    fun uppercaseFoldsToLowercase() {
        assertEquals("abcd", normalizedDisplayIdOrNull("ABCD"))
    }

    @Test
    fun mixedCaseFolds() {
        assertEquals("ab01cd", normalizedDisplayIdOrNull("Ab01cD"))
    }

    @Test
    fun upperAndLowerCaseInputsConverge() {
        assertEquals(normalizedDisplayIdOrNull("EF01"), normalizedDisplayIdOrNull("ef01"))
    }

    @Test
    fun emptyStringIsNotCollapsedToNull() {
        // Unlike event-code normalization (beid#226), a displayId has no
        // "blank means absent" rule of its own — only a genuinely null
        // detectedDisplayId (Barnard B003 unavailable) means absent.
        assertEquals("", normalizedDisplayIdOrNull(""))
    }
}
