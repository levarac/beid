package org.levarac.beid.shared.event

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * RED evidence for beid#226: this vector table pins the canonical form
 * ruling (DECISIONS 2026-08-20 — trim surrounding whitespace, then fold
 * case; Unicode normalization and full-width/half-width folding are
 * explicitly out of scope). `normalizedEventCodeOrNull` does not exist yet,
 * so this file fails to compile — that is the licensing failure Step 2 of
 * docs/kmp-shared-foundation.md requires before implementation begins.
 *
 * Naming mirrors this same package's existing `normalizedEventCodeHashHexOrNull`
 * (EventInfoStore.kt) — same "normalized...OrNull" convention, different
 * input domain (raw user-typed code vs. hash-hex).
 */
class EventCodeNormalizationTest {
    @Test
    fun trimsSurroundingWhitespaceAndFoldsCase() {
        assertEquals("ethtokyo", normalizedEventCodeOrNull(" ETHTOKYO "))
    }

    @Test
    fun alreadyCanonicalIsUnchanged() {
        assertEquals("ethtokyo", normalizedEventCodeOrNull("ethtokyo"))
    }

    @Test
    fun upperAndLowerCaseInputsConverge() {
        assertEquals(normalizedEventCodeOrNull("ETHTOKYO"), normalizedEventCodeOrNull("ethtokyo"))
    }

    @Test
    fun mixedCaseFolds() {
        assertEquals("ethtokyo", normalizedEventCodeOrNull("EthTokyo"))
    }

    @Test
    fun trimsTabsAndNewlinesToo() {
        assertEquals("ethtokyo", normalizedEventCodeOrNull("\tethtokyo\n"))
    }

    @Test
    fun emptyStringIsNull() {
        assertNull(normalizedEventCodeOrNull(""))
    }

    @Test
    fun whitespaceOnlyIsNull() {
        assertNull(normalizedEventCodeOrNull("   "))
    }

    @Test
    fun singleCharacterIsPreserved() {
        assertEquals("a", normalizedEventCodeOrNull("A"))
    }

    @Test
    fun internalWhitespaceIsNotTrimmed() {
        // Only surrounding whitespace is stripped by the decided rule —
        // internal whitespace is part of the code's identity.
        assertEquals("eth tokyo", normalizedEventCodeOrNull(" Eth Tokyo "))
    }

    @Test
    fun fullWidthDigitsAreNotFoldedToHalfWidth() {
        // Pins the exclusion from DECISIONS 2026-08-20 as an explicit
        // invariant: full-width/half-width folding and Unicode
        // normalization (NFKC etc.) are out of scope. A full-width "０"
        // (U+FF10) must NOT become half-width "0" — they stay distinct
        // codes. If this ever needs to change, that is a new product
        // decision, not a bug fix to this function.
        assertEquals("event０", normalizedEventCodeOrNull("event０"))
    }
}
