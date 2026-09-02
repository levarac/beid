package org.levarac.beid.persistence

import java.util.UUID
import org.levarac.beid.sensing.SensingRecoverableSignature
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

/**
 * [BindingRecord] is beid's own local record of "this device has a
 * wallet-endorsed owner key" — field names/encoding beid controls (unlike
 * Barnard's canonical binding-text bytes, which this record only carries
 * hex-encoded values *of*). Mirrors iOS's `BindingRecord`
 * (`ios/Beid/Persistence/BindingRecord.swift`) field-for-field.
 */
class BindingRecordTest {
    @Test
    fun constructorHexEncodesRawInputsLowercaseAndGeneratesAFreshId() {
        val proofId = UUID.randomUUID()
        val record = BindingRecord(
            proofId = proofId,
            eventCode = "TEST-EVENT",
            walletAddress = "0x14791697260e4c9a71f18484c9f997b308e59325",
            eventSigningPublicKey = byteArrayOf(0x02, 0xAB.toByte(), 0xCD.toByte()),
            ownerPublicKey = byteArrayOf(0x03, 0x11, 0x22),
            chainId = 1,
            nonce = byteArrayOf(0x00, 0x01, 0x02),
            issuedAt = "2026-07-30T09:00:00Z",
            walletSignatureHex = "0x" + "0a".repeat(65),
            deviceSignature = SensingRecoverableSignature(
                r = ByteArray(32) { 0x01 },
                s = ByteArray(32) { 0x02 },
                v = 0,
            ),
        )

        assertNotNull(record.id)
        assertEquals(proofId, record.proofId)
        assertEquals("TEST-EVENT", record.eventCode)
        assertEquals("02abcd", record.eventSigningPublicKeyHex)
        assertEquals("031122", record.ownerPublicKeyHex)
        assertEquals(1L, record.chainId)
        assertEquals("000102", record.nonceHex)
        assertEquals("01".repeat(32), record.deviceSignatureRHex)
        assertEquals("02".repeat(32), record.deviceSignatureSHex)
        assertEquals(0, record.deviceSignatureV)
    }

    @Test
    fun twoRecordsFromTheSameInputsHaveDifferentIds() {
        fun make() = BindingRecord(
            proofId = UUID.randomUUID(),
            eventCode = "TEST-EVENT",
            walletAddress = "0x14791697260e4c9a71f18484c9f997b308e59325",
            eventSigningPublicKey = byteArrayOf(0x02),
            ownerPublicKey = byteArrayOf(0x03),
            chainId = 1,
            nonce = byteArrayOf(0x00),
            issuedAt = "2026-07-30T09:00:00Z",
            walletSignatureHex = "0x00",
            deviceSignature = SensingRecoverableSignature(r = byteArrayOf(1), s = byteArrayOf(2), v = 0),
        )

        assertEquals(false, make().id == make().id)
    }
}
