package org.levarac.beid.shared.sensing

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * RED evidence for beid#231 item 3: `defaultEventConfirmThreshold` does not
 * exist yet, so this file fails to compile — that is the licensing failure
 * Step 2 of docs/kmp-shared-foundation.md requires before implementation
 * begins.
 *
 * This assertion is deliberately a literal-vs-live-read comparison, not a
 * native-vs-shared comparison: comparing two live reads of the same shared
 * symbol would stay green under any mutation of the constant's value, since
 * both sides move together. Only a hardcoded literal on one side can catch
 * that class of regression — see the platform-side tests for the same
 * pattern (`BeidConfigTest` on Android, `BeidConfigThresholdTests` on iOS).
 */
class EventConfirmThresholdTest {

    @Test
    fun defaultThresholdIsThree() {
        assertEquals(3, defaultEventConfirmThreshold)
    }
}
