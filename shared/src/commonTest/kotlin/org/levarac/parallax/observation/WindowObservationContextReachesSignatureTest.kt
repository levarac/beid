package org.levarac.parallax.observation

import kotlin.test.Test
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * The event identity a host observes under must reach the bytes it signs.
 *
 * ## Why these live here rather than in the Android app module
 *
 * Two app-module window-ledger tests used to assert this, on the signed
 * observation structure, and they cannot any more (beid#374). Their canned
 * signature verified only because the context they built WAS this conformance
 * vector's context — same window id, event id, definition digest, observer
 * key, `finalizedAt`, ENIN and participant commitment. The join gate now
 * sources event identity from barnard's B005 vector instead, so that structure
 * is unreachable by construction: no arrangement of fixture values is both
 * this vector's context and a promoted candidate. And a window never closes
 * without a signature that verifies, because `signWithCompactSignatureHex`
 * throws and nothing catches it, so asserting further downstream was not an
 * option either.
 *
 * Here the same property is provable without any signature at all: the
 * prepared Sig_structure can be inspected directly, before a signer is ever
 * involved. That is strictly less machinery for the same guarantee.
 *
 * These assert the second half of the chain — a context's identity fields
 * reaching the signed bytes. The first half, the Android coordinator building
 * that context out of a `RegistryVerifiedJoinContext`, is covered by neither
 * these nor the app module and is filed as a follow-up.
 */
class WindowObservationContextReachesSignatureTest {
    @Test
    fun theEventIdAndDefinitionDigestAppearInTheSignedStructure() {
        val prepared = prepared(EVENT_ID_HEX, DEFINITION_DIGEST_HEX)

        val structure = prepared.signatureStructure.toByteArray().toLowercaseHex()
        assertTrue(EVENT_ID_HEX in structure, "the event id must reach the bytes the host signs")
        assertTrue(
            DEFINITION_DIGEST_HEX in structure,
            "the definition digest must reach the bytes the host signs",
        )
    }

    /**
     * The counterpart the moved tests actually existed for: one session's
     * signed window must not carry another session's identity. Asserting the
     * absence is what makes the presence above mean something.
     */
    @Test
    fun anotherSessionsIdentityDoesNotAppearInThisSessionsSignedStructure() {
        val prepared = prepared(EVENT_ID_HEX, DEFINITION_DIGEST_HEX)

        val structure = prepared.signatureStructure.toByteArray().toLowercaseHex()
        assertTrue(OTHER_EVENT_ID_HEX !in structure, "a different event's id must not leak in")
        assertTrue(OTHER_DIGEST_HEX !in structure, "a different definition's digest must not leak in")
    }

    private fun prepared(eventIdHex: String, definitionDigestHex: String): PreparedObservationV1 {
        val evidence = assertNotNull(
            createMutualSensingWindowEvidence(
                idHex = WINDOW_ID_HEX,
                eventIdHex = eventIdHex,
                eventDefinitionDigestHex = definitionDigestHex,
                observerHex = OBSERVER_HEX,
                finalizedAt = 1_800_000_000.0,
                reporterRpidHex = REPORTER_RPID_HEX,
                enin = 6_000_000L,
                observedRpidHexes = listOf(OBSERVED_RPID_HEX),
            ),
        )
        val result = prepareMutualSensingObservation(evidence)
        return assertNotNull((result as? ObservationPreparationResult.Eligible)?.prepared)
    }

    private companion object {
        const val WINDOW_ID_HEX = "00112233445566778899aabbccddeeff"
        const val EVENT_ID_HEX = "2121212121212121212121212121212121212121212121212121212121212121"
        const val DEFINITION_DIGEST_HEX = "2222222222222222222222222222222222222222222222222222222222222222"
        const val OTHER_EVENT_ID_HEX = "4141414141414141414141414141414141414141414141414141414141414141"
        const val OTHER_DIGEST_HEX = "4242424242424242424242424242424242424242424242424242424242424242"
        const val OBSERVER_HEX = "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
        const val REPORTER_RPID_HEX = "0110101010101010101010101010101010"
        const val OBSERVED_RPID_HEX = "0111111111111111111111111111111111"
    }
}

private fun ByteArray.toLowercaseHex(): String =
    joinToString(separator = "") { (it.toInt() and 0xff).toString(16).padStart(2, '0') }
