package org.levarac.beid.sensing

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Mutation evidence for beid#231 item 3: this compares the read value
 * against a hardcoded literal, not against a live read of the shared
 * constant. A test that compared `BeidConfig.eventConfirmThreshold` against
 * `org.levarac.beid.shared.sensing.defaultEventConfirmThreshold` directly
 * would stay green under any mutation of the shared constant's value, since
 * both sides would move together — this literal comparison is what actually
 * kills a broken or reverted delegation.
 */
class BeidConfigTest {

    @Test
    fun eventConfirmThresholdIsThree() {
        assertEquals(3, BeidConfig.eventConfirmThreshold)
    }
}
