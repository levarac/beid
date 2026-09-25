package org.levarac.beid.shared.eventkeysign

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNull

/**
 * The golden vector below is the one mizar's claim contract and evaluator
 * test against (mizar `docs/design/spec.md`, "App signature"). It was
 * generated with `@noble/curves` 2.3.0, independently of Barnard, from the
 * TEST-ONLY key `SHA256("beid/event-key-sign/v1 golden vector key")`, so a
 * layout drift on either side shows up as a digest mismatch here.
 */
class EventKeySignRequestTest {
    private val eventId = "996ab4d7cd0785199b715e6ff004f41ef740ead3b3363602ce1cb14b812d1f94"
    private val challenge = "a1".repeat(32)
    private val claimBody =
        "0000000000000000000000000000000000000000000000000000000000aa36a7" +
            "5fbdb2315678afecb367f032d93f642f64180aa3" +
            "70997970c51812dc3a010c7d01b50e0d17dc79c8"

    private val personhoodMessage =
        "ff626569642f6576656e742d6b65792d7369676e2f76310001" + eventId + challenge
    private val claimMessage =
        "ff626569642f6576656e742d6b65792d7369676e2f76310002" + eventId + claimBody

    private fun accepted(link: String): EventKeySignRequest =
        assertIs<EventKeySignParseResult.Accepted>(parseEventKeySignLink(link)).request

    private fun rejection(link: String): EventKeySignRejection =
        assertIs<EventKeySignParseResult.Rejected>(parseEventKeySignLink(link)).reason

    @Test
    fun personhoodLinkBuildsTheGoldenMessage() {
        val request = accepted("beid://event-key-sign?v=1&p=01&e=$eventId&b=$challenge&st=abc_DEF-123")

        assertEquals(EventKeySignPurpose.PERSONHOOD_BINDING, request.purpose)
        assertEquals(eventId, request.eventIdHex)
        assertEquals(challenge, request.challengeHex)
        assertNull(request.claimContractHex)
        assertEquals("abc_DEF-123", request.state)
        assertEquals(personhoodMessage, request.messageHex())
        assertEquals(89, request.messageHex().length / 2)
    }

    @Test
    fun claimLinkBuildsTheGoldenMessageAndDecodesItsFields() {
        val request = accepted("beid://event-key-sign?v=1&p=02&e=0x$eventId&b=0x$claimBody&st=s1")

        assertEquals(EventKeySignPurpose.CLAIM, request.purpose)
        assertEquals("11155111", request.chainIdDecimal)
        assertEquals("0x5fbdb2315678afecb367f032d93f642f64180aa3", request.claimContractHex)
        assertEquals("0x70997970c51812dc3a010c7d01b50e0d17dc79c8", request.recipientHex)
        assertNull(request.challengeHex)
        assertEquals(claimMessage, request.messageHex())
        assertEquals(129, request.messageHex().length / 2)
    }

    @Test
    fun upperCaseHexIsCanonicalisedToLowerCase() {
        val request = accepted(
            "beid://event-key-sign?v=1&p=02&e=${eventId.uppercase()}&b=${claimBody.uppercase()}&st=s1",
        )
        assertEquals(claimMessage, request.messageHex())
    }

    @Test
    fun parameterOrderDoesNotMatter() {
        val request = accepted("beid://event-key-sign?st=s1&b=$challenge&e=$eventId&p=01&v=1")
        assertEquals(personhoodMessage, request.messageHex())
    }

    @Test
    fun optionalExpectedEventKeyIsCarriedForTheNativeCrossCheck() {
        val key = "02157f569f4ba8298dc31bf69aaac9efc75c16f9f8fb1630cf06443610e6e26581"
        val request = accepted("beid://event-key-sign?v=1&p=01&e=$eventId&b=$challenge&st=s1&k=$key")
        assertEquals(key, request.expectedEventKeyHex)
    }

    @Test
    fun linksThatAreNotThisEntryPointAreRejected() {
        assertEquals(EventKeySignRejection.NOT_EVENT_KEY_SIGN_LINK, rejection("metamask://connect?x=1"))
        assertEquals(EventKeySignRejection.NOT_EVENT_KEY_SIGN_LINK, rejection("beid://other?v=1"))
        assertEquals(EventKeySignRejection.NOT_EVENT_KEY_SIGN_LINK, rejection("https://event-key-sign?v=1"))
        assertEquals(EventKeySignRejection.NOT_EVENT_KEY_SIGN_LINK, rejection("beid://event-key-sign/path?v=1"))
        assertEquals(EventKeySignRejection.NOT_EVENT_KEY_SIGN_LINK, rejection("beid://event-key-signer?v=1"))
    }

    @Test
    fun malformedQueriesAreRejected() {
        val base = "beid://event-key-sign?v=1&p=01&e=$eventId&b=$challenge&st=s1"
        assertEquals(EventKeySignRejection.MALFORMED_QUERY, rejection("beid://event-key-sign"))
        assertEquals(EventKeySignRejection.MALFORMED_QUERY, rejection("$base#frag"))
        assertEquals(EventKeySignRejection.MALFORMED_QUERY, rejection("$base&novalue"))
        assertEquals(EventKeySignRejection.MALFORMED_QUERY, rejection("$base&&v=1"))
        assertEquals(EventKeySignRejection.MALFORMED_QUERY, rejection(base.replace("st=s1", "st=a%20b")))
        assertEquals(EventKeySignRejection.DUPLICATE_PARAMETER, rejection("$base&p=02"))
        assertEquals(EventKeySignRejection.UNKNOWN_PARAMETER, rejection("$base&cb=evil"))
        // A URL-shaped value never gets as far as parameter names: `:`, `/`
        // and `.` are not in the accepted character set.
        assertEquals(EventKeySignRejection.MALFORMED_QUERY, rejection("$base&cb=https://evil.example"))
    }

    @Test
    fun missingOrUnsupportedFieldsAreRejected() {
        assertEquals(
            EventKeySignRejection.UNSUPPORTED_VERSION,
            rejection("beid://event-key-sign?v=2&p=01&e=$eventId&b=$challenge&st=s1"),
        )
        assertEquals(
            EventKeySignRejection.UNSUPPORTED_VERSION,
            rejection("beid://event-key-sign?p=01&e=$eventId&b=$challenge&st=s1"),
        )
        assertEquals(
            EventKeySignRejection.UNKNOWN_PURPOSE,
            rejection("beid://event-key-sign?v=1&p=03&e=$eventId&b=$challenge&st=s1"),
        )
        assertEquals(
            EventKeySignRejection.UNKNOWN_PURPOSE,
            rejection("beid://event-key-sign?v=1&p=1&e=$eventId&b=$challenge&st=s1"),
        )
        assertEquals(
            EventKeySignRejection.INVALID_EVENT_ID,
            rejection("beid://event-key-sign?v=1&p=01&e=${eventId.drop(2)}&b=$challenge&st=s1"),
        )
        assertEquals(
            EventKeySignRejection.INVALID_EVENT_ID,
            rejection("beid://event-key-sign?v=1&p=01&e=${"zz" + eventId.drop(2)}&b=$challenge&st=s1"),
        )
        assertEquals(
            EventKeySignRejection.INVALID_STATE,
            rejection("beid://event-key-sign?v=1&p=01&e=$eventId&b=$challenge"),
        )
        assertEquals(
            EventKeySignRejection.INVALID_STATE,
            rejection("beid://event-key-sign?v=1&p=01&e=$eventId&b=$challenge&st=${"x".repeat(65)}"),
        )
        assertEquals(
            EventKeySignRejection.INVALID_EVENT_KEY,
            rejection("beid://event-key-sign?v=1&p=01&e=$eventId&b=$challenge&st=s1&k=04${"00".repeat(32)}"),
        )
    }

    @Test
    fun bodiesMustHaveTheLengthAndContentOfTheirPurpose() {
        // A claim body presented as a personhood request (and vice versa) is
        // rejected by length, so one purpose can never be signed as the other.
        assertEquals(
            EventKeySignRejection.INVALID_BODY,
            rejection("beid://event-key-sign?v=1&p=01&e=$eventId&b=$claimBody&st=s1"),
        )
        assertEquals(
            EventKeySignRejection.INVALID_BODY,
            rejection("beid://event-key-sign?v=1&p=02&e=$eventId&b=$challenge&st=s1"),
        )
        val zeroRecipient = claimBody.dropLast(40) + "00".repeat(20)
        assertEquals(
            EventKeySignRejection.INVALID_BODY,
            rejection("beid://event-key-sign?v=1&p=02&e=$eventId&b=$zeroRecipient&st=s1"),
        )
        val zeroContract = claimBody.take(64) + "00".repeat(20) + claimBody.takeLast(40)
        assertEquals(
            EventKeySignRejection.INVALID_BODY,
            rejection("beid://event-key-sign?v=1&p=02&e=$eventId&b=$zeroContract&st=s1"),
        )
        val zeroChain = "00".repeat(32) + claimBody.drop(64)
        assertEquals(
            EventKeySignRejection.INVALID_BODY,
            rejection("beid://event-key-sign?v=1&p=02&e=$eventId&b=$zeroChain&st=s1"),
        )
        val hugeChain = "80" + "00".repeat(31) + claimBody.drop(64)
        assertEquals(
            EventKeySignRejection.INVALID_BODY,
            rejection("beid://event-key-sign?v=1&p=02&e=$eventId&b=$hugeChain&st=s1"),
        )
    }

    @Test
    fun everyMessageStartsWithTheReservedFirstByte() {
        // 0xFF cannot begin CBOR (COSE Sig_structure starts 0x84), a UTF-8
        // string (legacy WindowReport starts with the event code), or a
        // Barnard "barnard-…" tag, so no message here equals any other
        // message the event key signs.
        val personhood = accepted("beid://event-key-sign?v=1&p=01&e=$eventId&b=$challenge&st=s1")
        val claim = accepted("beid://event-key-sign?v=1&p=02&e=$eventId&b=$claimBody&st=s1")
        assertEquals("ff", personhood.messageHex().take(2))
        assertEquals("ff", claim.messageHex().take(2))
    }

    @Test
    fun successFragmentCarriesAnEthereumStyleSignature() {
        val fragment = eventKeySignSuccessFragment(
            state = "s1",
            rHex = "3f710e304a2fce9324cfd5540b90966bbc8cdd1969d4461e51ae658404571dcb",
            sHex = "73b3866bb6649866d99b2f467f1e768c5144ce5e7126c1deb86c77ffb6dcf758",
            recoveryId = 0,
            eventKeyHex = "02157f569f4ba8298dc31bf69aaac9efc75c16f9f8fb1630cf06443610e6e26581",
            eventKeyAddressHex = "0x05e8bdca0d0523483bc1a2f490a2f03cb00b776d",
        )
        assertEquals(
            "v=1&st=s1" +
                "&sig=0x3f710e304a2fce9324cfd5540b90966bbc8cdd1969d4461e51ae658404571dcb" +
                "73b3866bb6649866d99b2f467f1e768c5144ce5e7126c1deb86c77ffb6dcf7581b" +
                "&k=0x02157f569f4ba8298dc31bf69aaac9efc75c16f9f8fb1630cf06443610e6e26581" +
                "&a=0x05e8bdca0d0523483bc1a2f490a2f03cb00b776d",
            fragment,
        )
    }

    @Test
    fun successFragmentRejectsOutOfProfileSignatures() {
        val r = "3f710e304a2fce9324cfd5540b90966bbc8cdd1969d4461e51ae658404571dcb"
        val s = "73b3866bb6649866d99b2f467f1e768c5144ce5e7126c1deb86c77ffb6dcf758"
        val key = "02157f569f4ba8298dc31bf69aaac9efc75c16f9f8fb1630cf06443610e6e26581"
        val address = "0x05e8bdca0d0523483bc1a2f490a2f03cb00b776d"
        assertNull(eventKeySignSuccessFragment("s1", r, s, 2, key, address))
        assertNull(eventKeySignSuccessFragment("s1", r.drop(2), s, 0, key, address))
        assertNull(eventKeySignSuccessFragment("s1", r, s, 1, key.drop(2), address))
        assertNull(eventKeySignSuccessFragment("s1", r, s, 1, key, address.drop(4)))
        assertNull(eventKeySignSuccessFragment("bad state", r, s, 1, key, address))
    }

    @Test
    fun cancelledFragmentEchoesOnlyTheState() {
        assertEquals("v=1&st=s1&err=cancelled", eventKeySignCancelledFragment("s1"))
        assertNull(eventKeySignCancelledFragment("bad state"))
    }
}
