package org.levarac.beid.shared.event

import org.levarac.parallax.discovery.NearbyEventJoinEligibility
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * beid#463's two shared rescue decisions: when the surface offers the paste
 * route, and what a participant is told when a join does not start.
 */
class EventRescueEntryTest {
    @Test
    fun aSearchThatHasNotRunLongEnoughKeepsSearching() {
        assertEquals(
            NearbyEventSearchOutcome.SEARCHING,
            nearbyEventSearchOutcome(RESCUE_ENTRY_DELAY_SECONDS - 1, joinableCandidateCount = 0),
        )
    }

    @Test
    fun aSearchThatFoundNothingJoinableOffersTheRescueRoute() {
        assertEquals(
            NearbyEventSearchOutcome.RESCUE_ENTRY_OFFERED,
            nearbyEventSearchOutcome(RESCUE_ENTRY_DELAY_SECONDS, joinableCandidateCount = 0),
        )
        assertEquals(
            NearbyEventSearchOutcome.RESCUE_ENTRY_OFFERED,
            nearbyEventSearchOutcome(RESCUE_ENTRY_DELAY_SECONDS + 600, joinableCandidateCount = 0),
        )
    }

    /**
     * The boundary that matters most, and the one a "no cards on screen"
     * implementation gets wrong. Cards for candidates that cannot be joined —
     * seen on the radio, not resolved to an Event ID — fill the screen while
     * leaving the participant with nothing to tap. Rescue is decided on
     * joinable candidates, so a screen full of unjoinable ones still offers it.
     */
    @Test
    fun unjoinableCandidatesOnScreenDoNotSuppressTheRescueRoute() {
        assertEquals(
            NearbyEventSearchOutcome.RESCUE_ENTRY_OFFERED,
            nearbyEventSearchOutcome(RESCUE_ENTRY_DELAY_SECONDS, joinableCandidateCount = 0),
        )
        assertEquals(
            NearbyEventSearchOutcome.SEARCHING,
            nearbyEventSearchOutcome(RESCUE_ENTRY_DELAY_SECONDS, joinableCandidateCount = 1),
        )
    }

    @Test
    fun aClockThatWentBackwardsDoesNotEndTheSearch() {
        assertEquals(
            NearbyEventSearchOutcome.SEARCHING,
            nearbyEventSearchOutcome(-1L, joinableCandidateCount = 0),
        )
    }

    /**
     * Acceptance condition 3. Every way the device can fail to reach the
     * registry has to arrive at the one reason a participant can act on, and
     * these are the exact wire names the registry produces — see
     * `RegistryErrorCode` and the lookup/definition error names in
     * `RegistryClient`.
     */
    @Test
    fun everyTransportFailureReadsAsNetworkRequired() {
        val transportCodes = listOf(
            "timeout",
            "rate_limited",
            "server_error",
            "http_error",
            "no_endpoint",
            "event_code_lookup_http_error",
            "definition_http_error",
            "definition_key_set_http_error",
        )
        for (code in transportCodes) {
            assertEquals(
                EventJoinFailureReason.NETWORK_REQUIRED,
                eventJoinFailureReasonForRegistryErrorCode(code),
                "expected $code to read as a network failure",
            )
        }
    }

    /**
     * The other half of the same condition, and the reason it is not enough to
     * assert that transport errors map to the network reason: a mapping that
     * answered NETWORK_REQUIRED for everything would pass the test above. A
     * code that means "this event does not exist" must not send the
     * participant looking for Wi-Fi.
     */
    @Test
    fun aMissingEventDoesNotReadAsNetworkRequired() {
        assertEquals(
            EventJoinFailureReason.EVENT_NOT_FOUND,
            eventJoinFailureReasonForRegistryErrorCode("event_code_lookup_not_found"),
        )
        assertEquals(
            EventJoinFailureReason.EVENT_NOT_FOUND,
            eventJoinFailureReasonForRegistryErrorCode("definition_not_found"),
        )
    }

    @Test
    fun aDeploymentWithNoLookupConfiguredIsNotANetworkProblem() {
        assertEquals(
            EventJoinFailureReason.VERIFICATION_FAILED,
            eventJoinFailureReasonForRegistryErrorCode("event_code_lookup_not_configured"),
        )
        assertEquals(
            EventJoinFailureReason.VERIFICATION_FAILED,
            eventJoinFailureReasonForRegistryErrorCode("definition_invalid_url_template"),
        )
    }

    @Test
    fun anAnswerThatDidNotVerifyIsNotANetworkProblem() {
        assertEquals(
            EventJoinFailureReason.VERIFICATION_FAILED,
            eventJoinFailureReasonForRegistryErrorCode("definition_hash_mismatch"),
        )
        assertEquals(
            EventJoinFailureReason.VERIFICATION_FAILED,
            eventJoinFailureReasonForRegistryErrorCode("event_code_lookup_invalid_response"),
        )
    }

    @Test
    fun anUnrecognizedCodeIsReportedAsUnknownRatherThanGuessedAt() {
        assertEquals(EventJoinFailureReason.UNKNOWN, eventJoinFailureReasonForRegistryErrorCode(null))
        assertEquals(
            EventJoinFailureReason.UNKNOWN,
            eventJoinFailureReasonForRegistryErrorCode("some_code_added_after_this_test_was_written"),
        )
    }

    /**
     * A code that resolved to a different event is the participant's problem
     * to fix — they were handed the wrong string, or the one they pasted was
     * truncated — and it is emphatically not a network failure, even though it
     * arrives at the same dead end.
     */
    @Test
    fun aCodeThatResolvedToADifferentEventReadsAsACodeMismatch() {
        assertEquals(
            EventJoinFailureReason.CODE_MISMATCH,
            eventJoinFailureReasonForJoinEligibility(NearbyEventJoinEligibility.CODE_NOT_BOUND),
        )
    }

    @Test
    fun anEventOutsideItsWindowReadsAsNotActive() {
        assertEquals(
            EventJoinFailureReason.EVENT_NOT_ACTIVE,
            eventJoinFailureReasonForJoinEligibility(NearbyEventJoinEligibility.DEFINITION_EXPIRED),
        )
        assertEquals(
            EventJoinFailureReason.EVENT_NOT_ACTIVE,
            eventJoinFailureReasonForJoinEligibility(NearbyEventJoinEligibility.NOT_OPEN_ADMISSION),
        )
    }

    /**
     * A resolution that exists and carries no definition means the network
     * worked and the answer was empty. Calling that a network failure would be
     * the most plausible-sounding wrong message this mapping could produce.
     */
    @Test
    fun anEmptyAnswerIsNotReportedAsANetworkFailure() {
        assertEquals(
            EventJoinFailureReason.VERIFICATION_FAILED,
            eventJoinFailureReasonForJoinEligibility(NearbyEventJoinEligibility.READ_FAILED),
        )
    }
}
