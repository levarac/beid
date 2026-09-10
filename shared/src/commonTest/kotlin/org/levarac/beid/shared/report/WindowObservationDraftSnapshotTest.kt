package org.levarac.beid.shared.report

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class WindowObservationDraftSnapshotTest {
    @Test
    fun canonicalTextIsTheDocumentedGoldenVector() {
        val draft = draftWith(RPID_TWO, RPID_ONE)

        assertEquals(
            "beid-window-observation-draft\t1\n" +
                "window\t30303131323233332d343435352d363637372d383839392d616162626363646465656666\n" +
                "enin\t6000000\n" +
                "event-code\t6576656e74\n" +
                "event-id\t${"21".repeat(32)}\n" +
                "event-definition-digest\t${"22".repeat(32)}\n" +
                "participant-commitment\t${"ab".repeat(32)}\n" +
                "reporter-rpid\t$REPORTER_RPID\n" +
                "observed-rpids\t2\n" +
                "rpid\t$RPID_TWO\n" +
                "rpid\t$RPID_ONE\n" +
                "end\n",
            encodeWindowObservationDraftSnapshot(draft),
        )
    }

    /**
     * Arrival order survives the round trip. The signed observation does not
     * depend on it — preparation sorts the set — but a decoder that imposed
     * an order of its own would be inventing a fact about what happened, and
     * the canonical-text check below would then reject perfectly good bytes.
     */
    @Test
    fun roundTripPreservesEveryFieldAndTheArrivalOrderOfTheSet() {
        val encoded = encodeWindowObservationDraftSnapshot(draftWith(RPID_TWO, RPID_ONE))

        val decoded = decodeWindowObservationDraftSnapshot(encoded)

        assertTrue(decoded.isSuccess)
        val draft = assertNotNull(decoded.draft)
        assertEquals(WINDOW_ID, draft.windowId)
        assertEquals(6_000_000L, draft.enin)
        assertEquals(EVENT_CODE, draft.eventCode)
        assertEquals("21".repeat(32), draft.eventIdHex)
        assertEquals("22".repeat(32), draft.eventDefinitionDigestHex)
        assertEquals("ab".repeat(32), draft.participantCommitmentHex)
        assertEquals(REPORTER_RPID, draft.reporterRpidHex)
        assertEquals(2, draft.observedRpidCount)
        assertEquals(RPID_TWO, draft.observedRpidAt(0))
        assertEquals(RPID_ONE, draft.observedRpidAt(1))
        assertNull(draft.observedRpidAt(2))
        assertEquals(encoded, encodeWindowObservationDraftSnapshot(draft))
    }

    @Test
    fun absentParticipantCommitmentRoundTripsAsAbsentRatherThanEmpty() {
        val created = assertNotNull(
            createWindowObservationDraft(
                windowId = WINDOW_ID,
                enin = 0L,
                eventCode = EVENT_CODE,
                eventIdHex = "21".repeat(32),
                eventDefinitionDigestHex = "22".repeat(32),
                participantCommitmentHex = null,
                reporterRpidHex = REPORTER_RPID,
            ).draft,
        )

        val decoded = decodeWindowObservationDraftSnapshot(
            encodeWindowObservationDraftSnapshot(created),
        )

        assertNull(assertNotNull(decoded.draft).participantCommitmentHex)
    }

    /**
     * The property that matters most in this file: bytes that do not decode
     * must not become a draft that observed nothing. "Nothing was observed"
     * and "the record could not be read" are different claims, and only the
     * second one is true here. Reporting the first would let a window that
     * saw a room full of people be finalized as empty.
     */
    @Test
    fun unreadableTextIsAFailureAndNeverAnEmptyDraft() {
        listOf(
            "",
            "not a snapshot\n",
            "beid-window-observation-draft\t2\nend\n",
            encodeWindowObservationDraftSnapshot(draftWith(RPID_ONE)).replace("\n", "\r\n"),
            encodeWindowObservationDraftSnapshot(draftWith(RPID_ONE)).removeSuffix("end\n"),
        ).forEach { encoded ->
            val decoded = decodeWindowObservationDraftSnapshot(encoded)

            assertFalse(decoded.isSuccess, "must reject: $encoded")
            assertNull(decoded.draft, "a rejected draft is never a blank one: $encoded")
            assertNotNull(decoded.errorCode)
        }
    }

    @Test
    fun aCountThatDisagreesWithTheRowsIsRejected() {
        val encoded = encodeWindowObservationDraftSnapshot(draftWith(RPID_ONE, RPID_TWO))

        val understated = decodeWindowObservationDraftSnapshot(
            encoded.replace("observed-rpids\t2", "observed-rpids\t1"),
        )
        val overstated = decodeWindowObservationDraftSnapshot(
            encoded.replace("observed-rpids\t2", "observed-rpids\t3"),
        )

        assertFalse(understated.isSuccess)
        assertFalse(overstated.isSuccess)
    }

    /**
     * A duplicate row would silently shrink the observed set on decode, so a
     * restored window would be signed over fewer peers than the device saw.
     * Rejecting it keeps the count line and the rows one single truth.
     */
    @Test
    fun aDuplicateObservedRpidRowIsRejectedRatherThanCollapsed() {
        val encoded = encodeWindowObservationDraftSnapshot(draftWith(RPID_ONE, RPID_TWO))

        val decoded = decodeWindowObservationDraftSnapshot(
            encoded.replace("rpid\t$RPID_TWO", "rpid\t$RPID_ONE"),
        )

        assertFalse(decoded.isSuccess)
        assertNull(decoded.draft)
    }

    @Test
    fun creationRejectsMalformedFieldsWithADistinguishableCode() {
        fun create(
            windowId: String = WINDOW_ID,
            enin: Long = 0L,
            eventCode: String = EVENT_CODE,
            eventIdHex: String = "21".repeat(32),
            eventDefinitionDigestHex: String = "22".repeat(32),
            participantCommitmentHex: String? = null,
            reporterRpidHex: String = REPORTER_RPID,
        ) = createWindowObservationDraft(
            windowId, enin, eventCode, eventIdHex, eventDefinitionDigestHex,
            participantCommitmentHex, reporterRpidHex,
        )

        assertEquals("invalid_window_id", create(windowId = "").errorCode)
        assertEquals("invalid_enin", create(enin = -1L).errorCode)
        assertEquals("invalid_event_code", create(eventCode = "").errorCode)
        assertEquals("invalid_event_id", create(eventIdHex = "2").errorCode)
        assertEquals("invalid_event_id", create(eventIdHex = "ZZ").errorCode)
        assertEquals("invalid_event_id", create(eventIdHex = "AB").errorCode)
        assertEquals(
            "invalid_event_definition_digest",
            create(eventDefinitionDigestHex = "").errorCode,
        )
        assertEquals(
            "invalid_participant_commitment",
            create(participantCommitmentHex = "xyz").errorCode,
        )
        assertEquals("invalid_reporter_rpid", create(reporterRpidHex = "0").errorCode)
        assertNull(create().errorCode)
    }

    /**
     * A peer detected twice inside one window is ordinary, not an error, so
     * re-adding it succeeds and changes nothing. A malformed one is an error.
     */
    @Test
    fun readdingAnObservedRpidIsANoOpAndMalformedInputIsRejected() {
        val draft = draftWith(RPID_ONE)

        val repeated = addWindowObservationDraftRpid(draft, RPID_ONE)
        val malformed = addWindowObservationDraftRpid(draft, "not-hex")

        assertTrue(repeated.isSuccess)
        assertEquals(1, assertNotNull(repeated.draft).observedRpidCount)
        assertFalse(malformed.isSuccess)
        assertEquals("invalid_observed_rpid", malformed.errorCode)
        assertNull(malformed.draft)
    }

    private fun draftWith(vararg observedRpids: String): WindowObservationDraft {
        var draft = assertNotNull(
            createWindowObservationDraft(
                windowId = WINDOW_ID,
                enin = 6_000_000L,
                eventCode = EVENT_CODE,
                eventIdHex = "21".repeat(32),
                eventDefinitionDigestHex = "22".repeat(32),
                participantCommitmentHex = "ab".repeat(32),
                reporterRpidHex = REPORTER_RPID,
            ).draft,
        )
        observedRpids.forEach { rpid ->
            draft = assertNotNull(addWindowObservationDraftRpid(draft, rpid).draft)
        }
        return draft
    }

    private companion object {
        const val WINDOW_ID = "00112233-4455-6677-8899-aabbccddeeff"
        const val EVENT_CODE = "event"
        const val REPORTER_RPID = "0110101010101010101010101010101010"
        const val RPID_ONE = "0111111111111111111111111111111111"
        const val RPID_TWO = "0122222222222222222222222222222222"
    }
}
