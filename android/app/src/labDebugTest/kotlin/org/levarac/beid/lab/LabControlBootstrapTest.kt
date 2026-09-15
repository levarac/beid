package org.levarac.beid.lab

import kotlin.test.Test
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class LabControlBootstrapTest {
    @Test
    fun identityRequiresExactHostFields() {
        assertFailsWith<IllegalArgumentException> {
            LabControlIdentity("", "participant", "device-1", 1, "token", 1)
        }
        assertFailsWith<IllegalArgumentException> {
            LabControlIdentity("run-1", "participant", "device-1", 1, "token", 2)
        }
    }

    @Test
    fun missingBrokerFailsClosed() {
        val identity = LabControlIdentity("run-1", "participant", "device-1", 1, "token", 1)
        val result = LabControlBootstrap(identity, "", LabWebSocketClient { _, _, _, _ -> }, { "state=idle" }).start()
        assertTrue(result.isFailure)
    }
}
