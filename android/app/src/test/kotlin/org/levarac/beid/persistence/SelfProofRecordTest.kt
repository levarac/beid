package org.levarac.beid.persistence

import java.time.Instant
import java.util.UUID
import org.levarac.beid.sensing.SensingRecoverableSignature
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

/**
 * [SelfProofRecord] is beid's own local record of one owner-key-signed
 * self-proof. Mirrors iOS's `SelfProofRecord`
 * (`ios/Beid/Persistence/SelfProofRecord.swift`) field-for-field.
 */
class SelfProofRecordTest {
    @Test
    fun constructorHexEncodesRawInputsLowercaseAndGeneratesAFreshId() {
        val proofId = UUID.randomUUID()
        val signedAt = Instant.parse("2026-01-01T00:00:00Z")

        val record = SelfProofRecord(
            proofId = proofId,
            eventCode = "TEST-EVENT",
            eventIdHash = ByteArray(32) { 0xAB.toByte() },
            eventSigningPublicKey = byteArrayOf(0x02, 0xC6.toByte()),
            eninStart = 100,
            eninEnd = 200,
            ownerPublicKey = byteArrayOf(0x03, 0x87.toByte()),
            signature = SensingRecoverableSignature(r = byteArrayOf(0x01), s = byteArrayOf(0x02), v = 0),
            signedAt = signedAt,
        )

        assertNotNull(record.id)
        assertEquals(proofId, record.proofId)
        assertEquals("TEST-EVENT", record.eventCode)
        assertEquals("ab".repeat(32), record.eventIdHashHex)
        assertEquals("02c6", record.eventSigningPublicKeyHex)
        assertEquals(100L, record.eninStart)
        assertEquals(200L, record.eninEnd)
        assertEquals("0387", record.ownerPublicKeyHex)
        assertEquals("01", record.signatureRHex)
        assertEquals("02", record.signatureSHex)
        assertEquals(0, record.signatureV)
        assertEquals(signedAt, record.signedAt)
    }
}
