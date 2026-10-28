package org.levarac.parallax.venue

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

/** Import vectors from ProductionVenueBundleVerifierTests and its shipped schedule rules. */
class VenueBundleScheduleTest {
    private fun envelope(from: Long, to: Long, cadence: Int = 300, at: Long = from, through: Long = 6_000_010) =
        VenueVerifiedScheduling(from, through, to, cadence, at)

    private fun check(vararg envelopes: VenueVerifiedScheduling?) = verifyVenueBundleSchedule(
        envelopes.toList(), 1_799_997_000, 1_800_003_299,
    )

    private fun rejects(code: String, vararg envelopes: VenueVerifiedScheduling?) {
        val result = check(*envelopes)
        assertNull(result.schedule)
        assertEquals(code, result.failureCode)
    }

    @Test fun validMultiSliceScheduleMayArriveOutOfOrder() {
        val result = check(envelope(6_000_004, 6_000_010), envelope(5_999_990, 6_000_000), envelope(6_000_000, 6_000_004))
        val schedule = assertNotNull(result.schedule)
        assertNull(result.failureCode)
        assertEquals(3, schedule.envelopeCount)
        assertEquals(300, schedule.eninSeconds)
        assertEquals(5_999_990L, schedule.requiredStartEnin)
        assertEquals(6_000_010L, schedule.requiredEndEnin)
    }

    @Test fun missingFutureSliceIsAGap() = rejects("gap", envelope(5_999_990, 6_000_004))
    @Test fun missingFirstSliceIsAGap() = rejects("gap", envelope(6_000_000, 6_000_010))
    @Test fun interiorGapIsRejected() = rejects("gap", envelope(5_999_990, 6_000_003), envelope(6_000_004, 6_000_010))
    @Test fun duplicateIsRejected() = rejects("overlap", envelope(5_999_990, 6_000_010), envelope(5_999_990, 6_000_010))
    @Test fun overlapIsRejectedEvenWhenUnionCoversEverything() =
        rejects("overlap", envelope(5_999_990, 6_000_005), envelope(6_000_003, 6_000_010))
    @Test fun mixedCadenceIsRejectedEvenWithAdjacentWallClockIntervals() = rejects(
        "mixed_cadence", envelope(5_999_990, 6_000_000), envelope(1_800_000_000, 1_800_003_000, 1, through = 1_800_003_298),
    )
    @Test fun sdkRejectedEnvelopeRejectsWholeBundle() = rejects("malformed_envelope", envelope(5_999_990, 6_000_010), null)
    @Test fun noEnvelopesCannotProveCoverage() = rejects("malformed_envelope")
    @Test fun emptyEnvelopeIsMalformed() = rejects("malformed_envelope", envelope(5_999_990, 5_999_990))
    @Test fun nonPositiveCadenceIsMalformed() = rejects("malformed_envelope", envelope(5_999_990, 6_000_010, 0))
    @Test fun verificationAtInclusiveStartIsEligible() { assertNotNull(check(envelope(5_999_990, 6_000_010)).schedule) }
    @Test fun verificationAtLastEligibleEninIsEligible() {
        assertNotNull(check(envelope(5_999_990, 6_000_010, at = 6_000_009)).schedule)
    }
    // Barnard rejects these envelopes before either native adapter supplies scheduling.
    @Test fun nativeVerificationAtExclusiveExpiryRejectionRejectsBundle() = rejects("malformed_envelope", null)
    @Test fun nativeVerificationBeforeStartRejectionRejectsBundle() = rejects("malformed_envelope", null)
    @Test fun scheduleDoesNotRevalidateNativeVerificationTime() {
        for (at in listOf(5_999_989L, 6_000_010L)) {
            assertNotNull(check(envelope(5_999_990, 6_000_010, at = at)).schedule)
        }
    }
    @Test fun terminalDefinitionEninIsNotRequiredForCoverage() { assertNotNull(check(envelope(5_999_990, 6_000_010)).schedule) }
    @Test fun nativeAgreementBeforeDefinitionRejectionRejectsBundle() = rejects("malformed_envelope", null)
    @Test fun nativeAgreementAfterDefinitionRejectionRejectsBundle() = rejects("malformed_envelope", null)
    @Test fun nativeAgreementDeclaredWindowRejectionRejectsBundle() = rejects("malformed_envelope", null)
    @Test fun scheduleDoesNotRepeatNativeRegistryAgreement() {
        // Deliberately impossible native verdicts isolate ownership: shared checks coverage,
        // while the adapters must pass null for a failed Barnard registry agreement.
        assertNotNull(check(envelope(5_999_989, 6_000_010)).schedule)
        assertNotNull(check(envelope(5_999_990, 6_000_011, through = 6_000_011)).schedule)
        assertNotNull(check(envelope(5_999_990, 6_000_010, through = 6_000_011)).schedule)
    }
    @Test fun malformedDefinitionFailsClosed() {
        assertEquals("invalid_definition_window", verifyVenueBundleSchedule(listOf(envelope(1, 2)), 100, 0).failureCode)
        assertEquals("invalid_definition_window", verifyVenueBundleSchedule(listOf(envelope(1, 2)), -1, 100).failureCode)
    }
    @Test fun roundedDefinitionUsesOnlyCompleteEnins() {
        val result = verifyVenueBundleSchedule(listOf(envelope(2, 4, 10, through = 4)), 11, 49)
        assertNotNull(result.schedule)
        assertEquals(2L, result.schedule?.requiredStartEnin)
        assertEquals(4L, venueDefinitionEninWindow(11, 49, 10)?.end)
        assertNull(result.failureCode)
    }
    @Test fun normalizationOverflowFailsClosed() = rejects(
        "malformed_envelope", envelope(Long.MAX_VALUE - 1, Long.MAX_VALUE, 300, through = Long.MAX_VALUE),
    )
}
