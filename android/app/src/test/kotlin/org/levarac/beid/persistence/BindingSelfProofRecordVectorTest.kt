package org.levarac.beid.persistence

import java.time.Instant
import java.util.UUID
import org.levarac.beid.sensing.SensingRecoverableSignature
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Loads `vectors/binding-self-proof-record-v1.txt` (this module's test
 * resources; see that file's header for the full evidence chain) and
 * asserts [SelfProofRecord]/[BindingRecord]'s constructors map Barnard's
 * own already-conformance-proven bytes into the exact hex fields the
 * vector pins — the beid-side "same result for same inputs" (criterion 3)
 * check, anchored to the same literal values iOS's `BindingRecord.swift`/
 * `SelfProofRecord.swift` field semantics use, without needing an iOS
 * Simulator run.
 */
class BindingSelfProofRecordVectorTest {
    private val vector: Map<String, String> = loadVector("vectors/binding-self-proof-record-v1.txt")

    @Test
    fun selfProofRecordFieldsMatchTheVector() {
        val record = SelfProofRecord(
            proofId = UUID.randomUUID(),
            eventCode = vector.getValue("selfproof_event_code"),
            eventIdHash = vector.getValue("selfproof_event_id_hash").hexToBytes(),
            eventSigningPublicKey = vector.getValue("selfproof_event_signing_public_key").hexToBytes(),
            eninStart = vector.getValue("selfproof_enin_start").toLong(),
            eninEnd = vector.getValue("selfproof_enin_end").toLong(),
            ownerPublicKey = vector.getValue("selfproof_owner_public_key").hexToBytes(),
            signature = SensingRecoverableSignature(
                r = vector.getValue("selfproof_signature_r").hexToBytes(),
                s = vector.getValue("selfproof_signature_s").hexToBytes(),
                v = vector.getValue("selfproof_signature_v").toInt(),
            ),
            signedAt = Instant.EPOCH,
        )

        assertEquals(vector.getValue("selfproof_event_code"), record.eventCode)
        assertEquals(vector.getValue("selfproof_event_id_hash"), record.eventIdHashHex)
        assertEquals(vector.getValue("selfproof_event_signing_public_key"), record.eventSigningPublicKeyHex)
        assertEquals(vector.getValue("selfproof_enin_start").toLong(), record.eninStart)
        assertEquals(vector.getValue("selfproof_enin_end").toLong(), record.eninEnd)
        assertEquals(vector.getValue("selfproof_owner_public_key"), record.ownerPublicKeyHex)
        assertEquals(vector.getValue("selfproof_signature_r"), record.signatureRHex)
        assertEquals(vector.getValue("selfproof_signature_s"), record.signatureSHex)
        assertEquals(vector.getValue("selfproof_signature_v").toInt(), record.signatureV)
    }

    @Test
    fun bindingRecordCanonicalTextFieldsMatchTheVector() {
        val record = BindingRecord(
            proofId = UUID.randomUUID(),
            eventCode = vector.getValue("binding_event_code"),
            walletAddress = vector.getValue("binding_wallet_address"),
            eventSigningPublicKey = vector.getValue("binding_event_signing_public_key").hexToBytes(),
            ownerPublicKey = vector.getValue("binding_owner_public_key").hexToBytes(),
            chainId = vector.getValue("binding_chain_id").toLong(),
            nonce = vector.getValue("binding_nonce").hexToBytes(),
            issuedAt = vector.getValue("binding_issued_at"),
            walletSignatureHex = vector.getValue("binding_wallet_signature_hex"),
            // Placeholder — this test only checks the canonical-text-side
            // fields above; the device signature is checked separately in
            // bindingRecordDeviceSignatureFieldsMatchTheVector using the
            // walletack_* group's own (different) wallet fixture.
            deviceSignature = SensingRecoverableSignature(r = byteArrayOf(0), s = byteArrayOf(0), v = 0),
        )

        assertEquals(vector.getValue("binding_event_code"), record.eventCode)
        assertEquals(vector.getValue("binding_wallet_address"), record.walletAddress)
        assertEquals(vector.getValue("binding_event_signing_public_key"), record.eventSigningPublicKeyHex)
        assertEquals(vector.getValue("binding_owner_public_key"), record.ownerPublicKeyHex)
        assertEquals(vector.getValue("binding_chain_id").toLong(), record.chainId)
        assertEquals(vector.getValue("binding_nonce"), record.nonceHex)
        assertEquals(vector.getValue("binding_issued_at"), record.issuedAt)
        assertEquals(vector.getValue("binding_wallet_signature_hex"), record.walletSignatureHex)
    }

    @Test
    fun bindingRecordDeviceSignatureFieldsMatchTheVector() {
        val record = BindingRecord(
            proofId = UUID.randomUUID(),
            eventCode = "unused-for-this-check",
            walletAddress = vector.getValue("binding_ack_wallet_address"),
            eventSigningPublicKey = byteArrayOf(0),
            ownerPublicKey = byteArrayOf(0),
            chainId = 1,
            nonce = byteArrayOf(0),
            issuedAt = "unused-for-this-check",
            walletSignatureHex = "unused-for-this-check",
            deviceSignature = SensingRecoverableSignature(
                r = vector.getValue("binding_ack_device_signature_r").hexToBytes(),
                s = vector.getValue("binding_ack_device_signature_s").hexToBytes(),
                v = vector.getValue("binding_ack_device_signature_v").toInt(),
            ),
        )

        assertEquals(vector.getValue("binding_ack_wallet_address"), record.walletAddress)
        assertEquals(vector.getValue("binding_ack_device_signature_r"), record.deviceSignatureRHex)
        assertEquals(vector.getValue("binding_ack_device_signature_s"), record.deviceSignatureSHex)
        assertEquals(vector.getValue("binding_ack_device_signature_v").toInt(), record.deviceSignatureV)
    }
}

/**
 * Minimal parser for the `key=value` convention this vector file documents
 * in its own header (mirrors levarac/barnard's `test-vectors/README.md`
 * format, at the subset this file's values actually need: no `\n`/`\\`
 * escapes appear in any value here, so that decoding step is omitted).
 */
private fun loadVector(resourcePath: String): Map<String, String> {
    val stream = requireNotNull(object {}.javaClass.classLoader?.getResourceAsStream(resourcePath)) {
        "Missing test resource: $resourcePath"
    }
    return stream.bufferedReader(Charsets.UTF_8).useLines { lines ->
        lines
            .filter { it.isNotBlank() && !it.startsWith("#") }
            .associate { line ->
                val separator = line.indexOf('=')
                require(separator >= 0) { "Malformed vector line (no '='): $line" }
                line.substring(0, separator) to line.substring(separator + 1)
            }
    }
}

private fun String.hexToBytes(): ByteArray {
    require(length % 2 == 0) { "hex string must have an even length: $this" }
    return ByteArray(length / 2) { index -> substring(index * 2, index * 2 + 2).toInt(16).toByte() }
}
