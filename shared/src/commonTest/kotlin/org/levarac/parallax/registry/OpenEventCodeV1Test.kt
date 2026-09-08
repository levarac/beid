package org.levarac.parallax.registry

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.levarac.parallax.observation.readVectorResource
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

class OpenEventCodeV1Test {
    @Test
    fun canonicalVectorUsesLowercaseHexTextBeforeHashing() {
        val eventId = ByteArray(32) { it.toByte() }
        val canonical = canonicalOpenCodeV1(eventId)
        val fullDigest = Sha256.digest(canonical.encodeToByteArray())

        assertEquals(
            "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
            canonical,
        )
        assertEquals(
            "6c86c6aac5fb24bcf5d9939cb7d7d5645ce39418f449e03b262dd4fa14b4b92b",
            fullDigest.toHexWithoutPrefixForOpenCodeTest(),
        )
        assertContentEquals(
            "6c86c6aac5fb24bc".decodeHex(),
            eventCodeHashForOpenEventV1(eventId),
        )
    }

    @Test
    fun noncanonicalTextAndRawBytesDoNotMatchTheCanonicalOpenCodeVector() {
        val eventId = ByteArray(32) { it.toByte() }
        val canonical = canonicalOpenCodeV1(eventId)

        assertNotEquals(canonical, canonical.uppercase())
        assertNotEquals(canonical, "0x$canonical")
        assertNotEquals(canonical, "$canonical ")
        assertNotEquals(canonical, canonical.drop(1))
        assertFalse(
            Sha256.digest(eventId).copyOfRange(0, 8)
                .contentEquals(eventCodeHashForOpenEventV1(eventId)),
        )
    }
}

private fun ByteArray.toHexWithoutPrefixForOpenCodeTest(): String = buildString(size * 2) {
    for (byte in this@toHexWithoutPrefixForOpenCodeTest) {
        val value = byte.toInt() and 0xff
        append("0123456789abcdef"[value ushr 4])
        append("0123456789abcdef"[value and 0x0f])
    }

    /**
     * Parity with the OTHER SIDE's own output, rather than with our record of
     * it (beid#403).
     *
     * The assertions above are beid's literals. They are correct today, and
     * they would stay green if parallax changed the convention tomorrow,
     * because nothing in them is derived from parallax. This one reads the
     * vendored `open-event-code-v1` vector — emitted by parallax, byte-checked
     * against the pinned checkout by the cross-repo comparison — and requires
     * beid's implementation to reproduce it.
     *
     * That is the difference between "beid agrees with beid" and "beid agrees
     * with parallax", and it is the whole subject of beid#403: a stand-in for
     * something that lives elsewhere must be checked against what that thing
     * actually emits.
     */
    @Test
    fun theImplementationReproducesParallaxsOwnOpenEventCodeVector() {
        val vector = Json.parseToJsonElement(
            readVectorResource("vectors/positive/open-event-code-v1.json"),
        ).jsonObject
        val eventId = vector.getValue("eventIdHex").jsonPrimitive.content.decodeHex()

        assertEquals(
            vector.getValue("openCodeV1").jsonPrimitive.content,
            canonicalOpenCodeV1(eventId),
            "the canonical open code must be the one parallax publishes",
        )
        assertEquals(
            vector.getValue("sha256Hex").jsonPrimitive.content,
            Sha256.digest(canonicalOpenCodeV1(eventId).encodeToByteArray())
                .toHexWithoutPrefixForOpenCodeTest(),
        )
        assertContentEquals(
            vector.getValue("eventCodeHashHex").jsonPrimitive.content.decodeHex(),
            eventCodeHashForOpenEventV1(eventId),
            "the 8-byte event-code hash must be the one parallax publishes",
        )
    }

    /**
     * The negative half of the same vector: parallax enumerates the
     * near-miss spellings of the canonical code — uppercase, an `0x` prefix,
     * leading whitespace, a dropped leading zero — and the hash each one
     * would produce. None of them may be what this implementation produces.
     *
     * Read from the vector rather than restated here, so a spelling parallax
     * adds later arrives with the re-vendor instead of being missed.
     */
    @Test
    fun noNoncanonicalSpellingFromParallaxsNegativeVectorMatchesOurs() {
        val positive = Json.parseToJsonElement(
            readVectorResource("vectors/positive/open-event-code-v1.json"),
        ).jsonObject
        val eventId = positive.getValue("eventIdHex").jsonPrimitive.content.decodeHex()
        val ours = eventCodeHashForOpenEventV1(eventId).toHexWithoutPrefixForOpenCodeTest()

        val negative = Json.parseToJsonElement(
            readVectorResource("vectors/negative/open-event-code-v1.json"),
        ).jsonObject
        val cases = negative.getValue("cases").jsonArray
        assertTrue(cases.isNotEmpty(), "the negative vector must actually carry cases")
        for (case in cases) {
            val name = case.jsonObject.getValue("name").jsonPrimitive.content
            val hashHex = case.jsonObject.getValue("hashHex").jsonPrimitive.content
            assertNotEquals(hashHex, ours, "non-canonical spelling '$name' must not be our answer")
        }
    }
}
