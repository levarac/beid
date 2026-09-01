package org.levarac.beid.persistence

import java.io.File
import java.time.Instant
import java.util.UUID
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put

/** On-device JSON store for owner-key-signed self-proofs — same pattern as [BindingRecordStore]. See [SelfProofRecord]. */
class SelfProofRecordStore(file: File) {
    private val store = JsonRecordFileStore(
        file = file,
        schemaVersion = SCHEMA_VERSION,
        toJson = ::toJson,
        fromJson = ::fromJson,
    )

    val records: List<SelfProofRecord> get() = store.records
    val isPersistenceSuspended: Boolean get() = store.isPersistenceSuspended

    fun add(record: SelfProofRecord) = store.addRecord(record)

    /** A `Proof` gets at most one self-proof, so the first match is the only match. */
    fun recordForProofId(proofId: UUID): SelfProofRecord? = store.recordMatching { it.proofId == proofId }

    companion object {
        const val SCHEMA_VERSION = 1

        fun defaultFile(filesDir: File): File = File(filesDir, "self-proofs.json")

        private fun toJson(record: SelfProofRecord): JsonObject = buildJsonObject {
            put("id", record.id.toString())
            put("proofId", record.proofId.toString())
            put("eventCode", record.eventCode)
            put("eventIdHashHex", record.eventIdHashHex)
            put("eventSigningPublicKeyHex", record.eventSigningPublicKeyHex)
            put("eninStart", record.eninStart)
            put("eninEnd", record.eninEnd)
            put("ownerPublicKeyHex", record.ownerPublicKeyHex)
            put("signatureRHex", record.signatureRHex)
            put("signatureSHex", record.signatureSHex)
            put("signatureV", record.signatureV)
            put("signedAt", record.signedAt.toString())
        }

        private fun fromJson(json: JsonObject): SelfProofRecord = SelfProofRecord(
            id = UUID.fromString(json.getValue("id").jsonPrimitive.content),
            proofId = UUID.fromString(json.getValue("proofId").jsonPrimitive.content),
            eventCode = json.getValue("eventCode").jsonPrimitive.content,
            eventIdHashHex = json.getValue("eventIdHashHex").jsonPrimitive.content,
            eventSigningPublicKeyHex = json.getValue("eventSigningPublicKeyHex").jsonPrimitive.content,
            eninStart = json.getValue("eninStart").jsonPrimitive.long,
            eninEnd = json.getValue("eninEnd").jsonPrimitive.long,
            ownerPublicKeyHex = json.getValue("ownerPublicKeyHex").jsonPrimitive.content,
            signatureRHex = json.getValue("signatureRHex").jsonPrimitive.content,
            signatureSHex = json.getValue("signatureSHex").jsonPrimitive.content,
            signatureV = json.getValue("signatureV").jsonPrimitive.int,
            signedAt = Instant.parse(json.getValue("signedAt").jsonPrimitive.content),
        )
    }
}
