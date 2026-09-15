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
        val broker = object : LabWebSocketClient {
            override fun connect(url: String, hello: LabHello, productionState: () -> String, nearbyCandidates: () -> List<String>, joinNearbyEvent: (String, (Boolean, String?) -> Unit) -> Unit, onSnapshot: (LabSnapshot) -> Unit) = Unit
            override fun stop() = Unit
        }
        val result = LabControlBootstrap(identity, "", broker, { "state=idle" }, { emptyList() }, { _, completion -> completion(false, "not_connected") }).start()
        assertTrue(result.isFailure)
    }
}
