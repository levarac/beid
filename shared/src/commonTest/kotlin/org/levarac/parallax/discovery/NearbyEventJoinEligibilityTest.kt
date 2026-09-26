package org.levarac.parallax.discovery

import org.levarac.parallax.registry.EventJoinMode
import org.levarac.parallax.registry.eventCodeHashForOpenEventV1
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

/**
 * Which receiver tier may join a nearby candidate (beid#391).
 *
 * These are the rule itself, held where both hosts read it. They were pinned
 * in Android's `NearbyEventReceiverStateAdapterTest` first, and the names are
 * mirrored deliberately so the two suites can be read against each other and
 * an iOS suite can adopt them unchanged.
 *
 * ## The v1.0 rule these pin
 *
 * Nearby join requires [NearbyEventReceiverState.REGISTRY_VERIFIED] and
 * nothing less. `RADIO_SELF_VERIFIED` is never joinable, whatever the registry
 * says about the hash, and `UNVERIFIED` is never joinable however well its
 * registry read went. The operator-lookup registration is code-entry evidence;
 * on the nearby path it is a necessary condition and not a sufficient one.
 *
 * ## What is NOT here, and why
 *
 * The late-arrival ordering — an envelope observed after its hash already
 * resolved — is pinned in Android's adapter suite, not here. A version of it
 * did live here briefly and was wrong: it drove
 * [applyNearbyEventRegistryAgreementFromHex], which HAS NO PRODUCTION CALLER
 * on either platform, while both hosts take an inline path instead. The test
 * passed, looked like coverage, and left the shipping branch unwatched. That
 * entry point's own contract is pinned by [NearbyEventReceiverStateTest]
 * already, so repeating it here would have duplicated the door nothing uses
 * while the used one went unguarded.
 *
 * ## What Android keeps
 *
 * The card that a host renders from these candidates is an Android projection
 * with no counterpart here, and pinning that it FOLLOWS this rule is a
 * different property from the rule itself. That wiring stays in the app module
 * — see `NearbyEventReceiverStateAdapterTest.theCardFollowsTheSharedJoinEligibility`.
 * Moving it here would have left the projection unpinned, which is the exact
 * defect beid#374's review found in it.
 *
 * The unresolved-radio and promoted-candidate cases overlap with
 * `RegistryVerifiedJoinContextTest.aRadioSelfVerifiedCandidateIssuesNothing`
 * and `aPromotedCandidateInsideItsWindowIssuesTheCapability`, respectively.
 * This suite pins the tier rule; that suite also checks capability issuance.
 * The registered RADIO_SELF_VERIFIED combination is this suite's distinct
 * refusal case. The hint-only case additionally proves a real lookup resolved.
 */
class NearbyEventJoinEligibilityTest {
    /**
     * The pin the v1.0 ruling turns on, and the one that was missing.
     *
     * A forged but self-consistent envelope raises a hash to
     * `RADIO_SELF_VERIFIED` while a genuine operator-lookup registration sits
     * behind it. That pair is the strongest state that is still not joinable,
     * and it is what the old Android-local rule wrongly admitted.
     *
     * Note what makes this different from [aV2OnlyCandidateWithoutAnOperatorLookupStaysUnjoinable]:
     * the registry here is actually RESOLVED. A test that records an envelope
     * and never resolves leaves the hash at `UNRESOLVED` and pins nothing in
     * either direction, which is how this combination went unpinned before.
     */
    @Test
    fun radioSelfVerifiedWithAnOperatorLookupRegistrationIsNotJoinableOnTheNearbyPath() {
        val store = createNearbyEventDiscoveryStore()
        recordHint(store)
        resolveRegistry(store, envelopeAgrees = false)
        recordEnvelope(store, agreesWithRegistry = false)

        val candidate = assertNotNull(store.snapshot.candidateAt(0))
        assertEquals(NearbyEventReceiverState.RADIO_SELF_VERIFIED, candidate.receiverState)
        assertEquals(
            NearbyEventRegistryStatus.REGISTERED_VIA_OPERATOR_LOOKUP,
            candidate.registryStatus,
            "the registration is genuine -- it is the TIER that is not joinable",
        )
        assertEquals(
            NearbyEventJoinEligibility.NOT_REGISTRY_VERIFIED,
            nearbyCandidateJoinEligibility(store.snapshot, HASH, WINDOW_MIDPOINT),
        )
    }

    @Test
    fun hintOnlyCandidateStaysUnverifiedAndIsNotJoinableOnTheNearbyPath() {
        val store = createNearbyEventDiscoveryStore()
        recordHint(store)
        resolveRegistry(store, envelopeAgrees = false)

        val candidate = assertNotNull(store.snapshot.candidateAt(0))
        assertEquals(NearbyEventReceiverState.UNVERIFIED, candidate.receiverState)
        assertEquals(NearbyEventRegistryStatus.REGISTERED_VIA_OPERATOR_LOOKUP, candidate.registryStatus)
        assertEquals(
            NearbyEventJoinEligibility.NOT_REGISTRY_VERIFIED,
            nearbyCandidateJoinEligibility(store.snapshot, HASH, WINDOW_MIDPOINT),
            "a successful registry read does not make an unverified tier joinable",
        )
    }

    @Test
    fun aV2OnlyCandidateWithoutAnOperatorLookupStaysUnjoinableOnTheNearbyPath() {
        val store = createNearbyEventDiscoveryStore()
        recordEnvelope(store, agreesWithRegistry = false)

        val candidate = assertNotNull(store.snapshot.candidateAt(0))
        assertEquals(NearbyEventReceiverState.RADIO_SELF_VERIFIED, candidate.receiverState)
        assertEquals(NearbyEventRegistryStatus.UNRESOLVED, candidate.registryStatus)
        assertEquals(
            NearbyEventJoinEligibility.NOT_REGISTRY_VERIFIED,
            nearbyCandidateJoinEligibility(store.snapshot, HASH, WINDOW_MIDPOINT),
        )
    }

    @Test
    fun agreementOnAVerifiedDefinitionPromotesAndUnlocksJoinOnTheNearbyPath() {
        val store = createNearbyEventDiscoveryStore()
        recordEnvelope(store, agreesWithRegistry = false)
        resolveRegistry(store, envelopeAgrees = true)

        val candidate = assertNotNull(store.snapshot.candidateAt(0))
        assertEquals(NearbyEventReceiverState.REGISTRY_VERIFIED, candidate.receiverState)
        assertEquals(
            NearbyEventJoinEligibility.ELIGIBLE,
            nearbyCandidateJoinEligibility(store.snapshot, HASH, WINDOW_MIDPOINT),
        )
    }

    private fun recordHint(store: NearbyEventDiscoveryStore) {
        recordNearbyEventHint(store, "peripheral", "Beacon", HASH.hexBytes(), null, false, false, 1L)
    }

    private fun recordEnvelope(store: NearbyEventDiscoveryStore, agreesWithRegistry: Boolean) {
        recordNearbyEventRadioSelfVerifiedEnvelope(
            store = store,
            peripheralId = "peripheral",
            eventDisplayName = "Beacon",
            eventCodeHash = HASH.hexBytes(),
            rawContainer = CONTAINER,
            agreesWithRegistry = agreesWithRegistry,
            additionalNamesOmitted = false,
            additionalEventsOmitted = false,
            observedAtEpochMillis = 1L,
        )
    }

    private fun resolveRegistry(store: NearbyEventDiscoveryStore, envelopeAgrees: Boolean) {
        val attempt = assertNotNull(beginNearbyEventRegistryResolutionFromHex(store, HASH))
        completeNearbyEventRegistryResolutionFromHex(
            store = store,
            attempt = attempt,
            result = NearbyEventRegistryResolutionResult.VERIFIED,
            resolvedEventIdHex = EVENT_ID,
            verifiedDefinitionJoinMode = EventJoinMode.OPEN,
            verifiedDefinitionEventIdHex = EVENT_ID,
            verifiedDefinitionEventCodeHashHex = HASH,
            envelopeAgreesWithRegistry = envelopeAgrees,
            verifiedDefinitionHashHex = DEFINITION_HASH_HEX,
            registryBlockHashHex = BLOCK_HASH_HEX,
            verifiedDefinitionValidFromEpochSeconds = VALID_FROM,
            verifiedDefinitionValidUntilEpochSeconds = VALID_UNTIL,
        )
    }

    private companion object {
        val EVENT_ID_BYTES = ByteArray(32) { (it + 1).toByte() }
        val EVENT_ID = EVENT_ID_BYTES.toLowercaseHex()
        val HASH = eventCodeHashForOpenEventV1(EVENT_ID_BYTES).toLowercaseHex()
        val CONTAINER = byteArrayOf(3, 0, 1, 2)
        val DEFINITION_HASH_HEX = "ab".repeat(32)
        val BLOCK_HASH_HEX = "cd".repeat(32)
        const val VALID_FROM = 1_800_000_000L
        const val VALID_UNTIL = 1_900_000_000L
        const val WINDOW_MIDPOINT = 1_850_000_000L
    }
}

private fun ByteArray.toLowercaseHex(): String =
    joinToString(separator = "") { (it.toInt() and 0xff).toString(16).padStart(2, '0') }

private fun String.hexBytes(): ByteArray =
    chunked(2).map { it.toInt(16).toByte() }.toByteArray()
