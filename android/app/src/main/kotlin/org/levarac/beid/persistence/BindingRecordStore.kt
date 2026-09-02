package org.levarac.beid.persistence

import java.io.File
import java.util.UUID
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put

/**
 * On-device JSON store for completed wallet-binding records — same pattern
 * as iOS's `BindingRecordStore` (flat JSON, no server call, atomic write).
 * See [BindingRecord].
 */
class BindingRecordStore(file: File) {
    private val store = JsonRecordFileStore(
        file = file,
        schemaVersion = SCHEMA_VERSION,
        toJson = ::toJson,
        fromJson = ::fromJson,
    )

    val records: List<BindingRecord> get() = store.records
    val isPersistenceSuspended: Boolean get() = store.isPersistenceSuspended

    fun add(record: BindingRecord) = store.addRecord(record)

    /** A `Proof` is bound at most once, so the first match is the only match. */
    fun recordForProofId(proofId: UUID): BindingRecord? = store.recordMatching { it.proofId == proofId }

    companion object {
        const val SCHEMA_VERSION = 1

        /**
         * `v2`: pre-conformance records (a hypothetical `binding-records.json`)
         * would be orphaned by construction under this filename — mirrors
         * iOS's own filename bump (`docs/specs/barnard-binding-conformance.md`
         * §6.d). Android has no pre-conformance file to orphan (this is its
         * first binding-record slice), but the filename is chosen to match
         * iOS's for cross-platform legibility, not because a migration is
         * needed here.
         */
        fun defaultFile(filesDir: File): File = File(filesDir, "binding-records-v2.json")

        private fun toJson(record: BindingRecord): JsonObject = buildJsonObject {
            put("id", record.id.toString())
            put("proofId", record.proofId.toString())
            put("eventCode", record.eventCode)
            put("walletAddress", record.walletAddress)
            put("eventSigningPublicKeyHex", record.eventSigningPublicKeyHex)
            put("ownerPublicKeyHex", record.ownerPublicKeyHex)
            put("chainId", record.chainId)
            put("nonceHex", record.nonceHex)
            put("issuedAt", record.issuedAt)
            put("walletSignatureHex", record.walletSignatureHex)
            put("deviceSignatureRHex", record.deviceSignatureRHex)
            put("deviceSignatureSHex", record.deviceSignatureSHex)
            put("deviceSignatureV", record.deviceSignatureV)
        }

        private fun fromJson(json: JsonObject): BindingRecord = BindingRecord(
            id = UUID.fromString(json.getValue("id").jsonPrimitive.content),
            proofId = UUID.fromString(json.getValue("proofId").jsonPrimitive.content),
            eventCode = json.getValue("eventCode").jsonPrimitive.content,
            walletAddress = json.getValue("walletAddress").jsonPrimitive.content,
            eventSigningPublicKeyHex = json.getValue("eventSigningPublicKeyHex").jsonPrimitive.content,
            ownerPublicKeyHex = json.getValue("ownerPublicKeyHex").jsonPrimitive.content,
            chainId = json.getValue("chainId").jsonPrimitive.long,
            nonceHex = json.getValue("nonceHex").jsonPrimitive.content,
            issuedAt = json.getValue("issuedAt").jsonPrimitive.content,
            walletSignatureHex = json.getValue("walletSignatureHex").jsonPrimitive.content,
            deviceSignatureRHex = json.getValue("deviceSignatureRHex").jsonPrimitive.content,
            deviceSignatureSHex = json.getValue("deviceSignatureSHex").jsonPrimitive.content,
            deviceSignatureV = json.getValue("deviceSignatureV").jsonPrimitive.int,
        )
    }
}
