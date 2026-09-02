package org.levarac.beid.sensing

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * `EventIdHash` is beid's own construction choice (`SHA256(UTF8(eventCode))`,
 * `docs/specs/barnard-binding-conformance.md` §2.2's recommendation) — not
 * something Barnard pins. Mirrors `ios/BeidTests/SelfProofTests.swift`'s
 * `EventIdHashTests`, asserting against the standard NIST SHA-256 test
 * vectors (FIPS 180-4), an independent primary source, not beid's own
 * re-derivation.
 */
class EventIdHashTest {
    @Test
    fun computeMatchesNistSha256EmptyStringVector() {
        assertEquals(
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            EventIdHash.compute("").toHexString(),
        )
    }

    @Test
    fun computeMatchesNistSha256AbcVector() {
        assertEquals(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            EventIdHash.compute("abc").toHexString(),
        )
    }
}

private fun ByteArray.toHexString(): String = joinToString("") { "%02x".format(it) }
