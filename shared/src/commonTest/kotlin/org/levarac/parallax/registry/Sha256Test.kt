package org.levarac.parallax.registry

import kotlin.test.Test
import kotlin.test.assertEquals

class Sha256Test {
    @Test
    fun matchesNistAbcVector() {
        assertEquals(
            "0xba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            Sha256.digest("abc".encodeToByteArray()).toPrefixedHex(),
        )
    }
}
