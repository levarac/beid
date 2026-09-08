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
 * These assert PRESENCE only, and deliberately no longer assert absence. An
 * earlier version checked that a different event's id and digest do NOT appear
 * in the structure, which could not fail: the other values were never supplied
 * to anything, so no production change could have put them there. An assertion
 * that cannot fail is decoration, and padding this fixture until it merely
 * looked falsifiable would have recreated that with more ceremony.
 *
 * The absence property — one event's data not reaching another event's signed
 * window — is genuinely falsifiable one layer down, where a second event can
 * actually exist:
 * `WindowObservationAccumulatorTest.beginningASecondEventClosesTheFirstEventsOpenWindow`.
 * That test goes red when the guard it protects is removed.
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
        const val OBSERVER_HEX = "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
        const val REPORTER_RPID_HEX = "0110101010101010101010101010101010"
        const val OBSERVED_RPID_HEX = "0111111111111111111111111111111111"
    }
}

private fun ByteArray.toLowercaseHex(): String =
    joinToString(separator = "") { (it.toInt() and 0xff).toString(16).padStart(2, '0') }
