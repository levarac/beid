package org.levarac.parallax.submission

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class SubmissionOperatorConfigurationTest {
    @Test
    fun restoresThePersistedIdentityAndEventContext() {
        val configuration = assertNotNull(restoredConfiguration())

        assertEquals("https://operator.example/v1/observations", configuration.submissionEndpoint)
        assertEquals(RECEIPT_PUBLIC_KEY, configuration.receiptPublicKey.toString())
        assertEquals(OPERATOR_ID, configuration.operatorId.toString())
        assertEquals("11".repeat(32), configuration.eventId.toString())
        assertEquals("22".repeat(32), configuration.eventDefinitionDigest.toString())
        assertEquals(100L, configuration.validFrom)
        assertEquals(200L, configuration.validUntil)
    }

    @Test
    fun derivesTheExpectedOperatorIdentityWhenNoStoredIdentityExists() {
        val configuration = assertNotNull(restoredConfiguration(operatorIdHex = null))

        assertEquals(OPERATOR_ID, configuration.operatorId.toString())
    }

    @Test
    fun rejectsAStoredOperatorIdentityThatDoesNotBelongToTheReceiptKey() {
        assertNull(restoredConfiguration(operatorIdHex = "33".repeat(32)))
    }

    @Test
    fun aDifferentReceiptKeyRequiresItsOwnOperatorIdentity() {
        val otherPublicKey = "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
        val otherOperatorId = "86b2ee58869d9c418b98a7f0b94ab104c600b605b6e89e811acead12ed409114"

        assertNull(restoredConfiguration(receiptPublicKeyHex = otherPublicKey))
        val derived = assertNotNull(restoredConfiguration(
            receiptPublicKeyHex = otherPublicKey,
            operatorIdHex = null,
        ))
        assertEquals(otherOperatorId, derived.operatorId.toString())
        assertNotNull(restoredConfiguration(
            receiptPublicKeyHex = otherPublicKey,
            operatorIdHex = otherOperatorId,
        ))
    }

    @Test
    fun acceptsPrefixedUppercaseHexWithoutChangingTheStoredBytes() {
        val configuration = assertNotNull(restoredConfiguration(
            receiptPublicKeyHex = "0x" + RECEIPT_PUBLIC_KEY.uppercase(),
            operatorIdHex = "0x" + OPERATOR_ID.uppercase(),
            eventIdHex = "0x" + "AB".repeat(32),
            eventDefinitionDigestHex = "0x" + "CD".repeat(32),
        ))

        assertEquals(RECEIPT_PUBLIC_KEY, configuration.receiptPublicKey.toString())
        assertEquals(OPERATOR_ID, configuration.operatorId.toString())
        assertEquals("ab".repeat(32), configuration.eventId.toString())
        assertEquals("cd".repeat(32), configuration.eventDefinitionDigest.toString())
    }

    @Test
    fun rejectsMalformedReceiptKeyHex() {
        for (invalid in listOf("", "02", "00".repeat(32), "00".repeat(34), "gg".repeat(33))) {
            assertNull(restoredConfiguration(receiptPublicKeyHex = invalid), invalid)
        }
    }

    @Test
    fun rejectsMalformedStoredOperatorIdentityHex() {
        for (invalid in listOf("", "0", "00".repeat(31), "00".repeat(33), "gg".repeat(32))) {
            assertNull(restoredConfiguration(operatorIdHex = invalid), invalid)
        }
    }

    @Test
    fun rejectsMalformedEventAndDefinitionDigestHex() {
        for (invalid in listOf("", "0", "00".repeat(31), "00".repeat(33), "gg".repeat(32))) {
            assertNull(restoredConfiguration(eventIdHex = invalid), "event: $invalid")
            assertNull(restoredConfiguration(eventDefinitionDigestHex = invalid), "definition: $invalid")
        }
    }

    @Test
    fun preservesAbsentOptionalEventContext() {
        val configuration = assertNotNull(restoredConfiguration(
            eventIdHex = null,
            eventDefinitionDigestHex = null,
            validFrom = null,
            validUntil = null,
        ))

        assertNull(configuration.eventId)
        assertNull(configuration.eventDefinitionDigest)
        assertNull(configuration.validFrom)
        assertNull(configuration.validUntil)
    }

    @Test
    fun acceptsEqualValidityBounds() {
        val configuration = assertNotNull(restoredConfiguration(validFrom = 100, validUntil = 100))

        assertEquals(100L, configuration.validFrom)
        assertEquals(100L, configuration.validUntil)
    }

    @Test
    fun rejectsInvertedOrIncompleteValidityBounds() {
        assertNull(restoredConfiguration(validFrom = 201, validUntil = 200))
        assertNull(restoredConfiguration(validFrom = null, validUntil = 200))
        assertNull(restoredConfiguration(validFrom = 100, validUntil = null))
    }

    @Test
    fun removesTrailingSlashesWithoutDroppingTheEndpointPath() {
        val configuration = assertNotNull(restoredConfiguration(
            endpoint = "https://operator.example/v1/observations///",
        ))

        assertEquals("https://operator.example/v1/observations", configuration.submissionEndpoint)
    }

    @Test
    fun rejectsCleartextEndpointsUnlessTheLoopbackExceptionIsExplicit() {
        for (host in listOf("127.0.0.1", "localhost", "[::1]", "operator.example")) {
            assertNull(restoredConfiguration(endpoint = "http://$host:8787"), host)
        }
    }

    @Test
    fun theTestExceptionAllowsOnlyLoopbackHostsWithAnExplicitPort() {
        for (host in listOf("127.0.0.1", "localhost", "[::1]")) {
            val configuration = assertNotNull(restoredConfiguration(
                endpoint = "http://$host:8787/v1/observations",
                allowInsecureLoopbackForTests = true,
            ), host)
            assertEquals("http://$host:8787/v1/observations", configuration.submissionEndpoint)
            assertNull(restoredConfiguration(
                endpoint = "http://$host",
                allowInsecureLoopbackForTests = true,
            ), host)
        }
        for (host in listOf("operator.example", "localhost.example", "127.0.0.2", "[::2]")) {
            assertNull(restoredConfiguration(
                endpoint = "http://$host:8787",
                allowInsecureLoopbackForTests = true,
            ), host)
        }
    }

    @Test
    fun acceptsBothValidPortBounds() {
        for (port in listOf(1, 65_535)) {
            assertNotNull(restoredConfiguration(endpoint = "https://operator.example:$port"), "$port")
        }
    }

    @Test
    fun rejectsInvalidPorts() {
        for (port in listOf("", "0", "65536", "-1", "+1", "abc", "99999999999999999999")) {
            assertNull(restoredConfiguration(endpoint = "https://operator.example:$port"), port)
        }
    }

    @Test
    fun rejectsQueriesAndFragmentsIncludingEmptyOnes() {
        for (suffix in listOf("?", "?mode=test", "#", "#section")) {
            assertNull(restoredConfiguration(endpoint = "https://operator.example$suffix"), suffix)
        }
    }

    @Test
    fun rejectsMissingOrAmbiguousEndpointAuthorities() {
        for (endpoint in listOf(
            "operator.example",
            "https://",
            "https:///v1/observations",
            "https://user@operator.example",
            "https://operator.example\\other.example",
            "https://[::1",
            "https://[::1]extra",
            "https://::1",
        )) {
            assertNull(restoredConfiguration(endpoint = endpoint), endpoint)
        }
    }

    private fun restoredConfiguration(
        endpoint: String = "https://operator.example/v1/observations",
        receiptPublicKeyHex: String = RECEIPT_PUBLIC_KEY,
        operatorIdHex: String? = OPERATOR_ID,
        eventIdHex: String? = "11".repeat(32),
        eventDefinitionDigestHex: String? = "22".repeat(32),
        validFrom: Long? = 100,
        validUntil: Long? = 200,
        allowInsecureLoopbackForTests: Boolean = false,
    ): SubmissionOperatorConfiguration? = createSubmissionOperatorConfigurationWithOperatorId(
        endpoint = endpoint,
        receiptPublicKeyHex = receiptPublicKeyHex,
        operatorIdHex = operatorIdHex,
        eventIdHex = eventIdHex,
        eventDefinitionDigestHex = eventDefinitionDigestHex,
        validFrom = validFrom,
        validUntil = validUntil,
        allowInsecureLoopbackForTests = allowInsecureLoopbackForTests,
    )

    private companion object {
        // Public test-vector key and its independently pinned operator identity.
        const val RECEIPT_PUBLIC_KEY = "02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"
        const val OPERATOR_ID = "50d8f3689f95e95c30be32dc4e516460dff139c088ab1117af0c104188252949"
    }
}
