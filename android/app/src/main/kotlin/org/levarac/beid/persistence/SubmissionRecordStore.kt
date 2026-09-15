package org.levarac.beid.persistence

import java.io.File
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put

/**
 * On-device JSON store for [SubmissionRecord], one row per unsent-window
 * artifact — same `JsonRecordFileStore` pattern as [SelfProofRecordStore].
 *
 * This store answers only "what configuration, if any, governs this
 * artifact's submission, and what has native additionally learned about it
 * (an accepted receipt's bytes, a terminal failure's reason)". Whether an
 * artifact is eligible to submit at all, and its in-flight/retryable/
 * acknowledged lifecycle, stay in the shared ledger
 * (`UnsentWindowLedgerStore`) — this store never duplicates that state.
 */
internal class SubmissionRecordStore(file: File) {
    private val store = JsonRecordFileStore(
        file = file,
        schemaVersion = SCHEMA_VERSION,
        toJson = ::toJson,
        fromJson = ::fromJson,
    )

    val records: List<SubmissionRecord> get() = store.records

    fun recordFor(windowId: String): SubmissionRecord? = store.recordMatching { it.windowId == windowId }

    /**
     * Persists a resolved configuration for [windowId], or the reason none
     * could be resolved. Called once, at window-open — see
     * [org.levarac.beid.sensing.WindowObservationAccumulator]'s doc for why
     * open rather than close is the durability point that survives a crash
     * recovered through the draft-promotion path.
     */
    fun add(record: SubmissionRecord) = store.addRecord(record)

    /** Persists an accepted receipt's exact bytes before the ledger is ever told about the acceptance. */
    fun recordAcceptance(windowId: String, acceptanceReceiptHex: String): Boolean =
        store.updateRecord(
            predicate = { it.windowId == windowId },
            transform = { it.copy(acceptanceReceiptHex = acceptanceReceiptHex) },
        )

    /** Binds the exact ledger observation reference to the existing window record. */
    fun recordObservationDigest(windowId: String, observationDigestHex: String): Boolean =
        store.updateRecord(
            predicate = { it.windowId == windowId },
            transform = { it.copy(observationDigestHex = observationDigestHex) },
        )

    /** Records why automatic submission stopped for [windowId] — diagnosis only, never a merge gate for retry. */
    fun recordTerminalFailure(windowId: String, errorCode: String): Boolean =
        store.updateRecord(
            predicate = { it.windowId == windowId },
            transform = { it.copy(terminalErrorCode = errorCode) },
        )

    /**
     * Replaces a held record's configuration once a later registry lookup
     * (beid#525, the nearby-join path) resolves one — clears
     * [SubmissionRecord.unresolvedReason] atomically with setting the
     * resolved fields, so the invariant in [SubmissionRecord]'s `init` always
     * holds. Never called on a record that already has a configuration:
     * `WindowObservationSubmissionDrain` only attempts a registry lookup when
     * [recordFor] returned an unresolved record.
     */
    fun recordResolvedConfiguration(
        windowId: String,
        submissionEndpoint: String,
        receiptPublicKeyHex: String,
        operatorIdHex: String?,
        eventDefinitionDigestHex: String?,
        validFrom: Long?,
        validUntil: Long?,
    ): Boolean = store.updateRecord(
        predicate = { it.windowId == windowId },
        transform = {
            it.copy(
                submissionEndpoint = submissionEndpoint,
                receiptPublicKeyHex = receiptPublicKeyHex,
                operatorIdHex = operatorIdHex,
                eventDefinitionDigestHex = eventDefinitionDigestHex,
                validFrom = validFrom,
                validUntil = validUntil,
                unresolvedReason = null,
            )
        },
    )

    companion object {
        const val SCHEMA_VERSION = 1

        fun defaultFile(filesDir: File): File = File(filesDir, "submission-records-v1.json")

        private fun toJson(record: SubmissionRecord): JsonObject = buildJsonObject {
            put("windowId", record.windowId)
            put("eventIdHex", record.eventIdHex)
            put("submissionEndpoint", record.submissionEndpoint)
            put("receiptPublicKeyHex", record.receiptPublicKeyHex)
            put("operatorIdHex", record.operatorIdHex)
            put("eventDefinitionDigestHex", record.eventDefinitionDigestHex)
            put("validFrom", record.validFrom)
            put("validUntil", record.validUntil)
            put("unresolvedReason", record.unresolvedReason)
            put("acceptanceReceiptHex", record.acceptanceReceiptHex)
            put("terminalErrorCode", record.terminalErrorCode)
            put("observationDigestHex", record.observationDigestHex)
        }

        private fun fromJson(json: JsonObject): SubmissionRecord = SubmissionRecord(
            windowId = json.getValue("windowId").jsonPrimitive.content,
            eventIdHex = json.getValue("eventIdHex").jsonPrimitive.content,
            submissionEndpoint = json.stringOrNull("submissionEndpoint"),
            receiptPublicKeyHex = json.stringOrNull("receiptPublicKeyHex"),
            operatorIdHex = json.stringOrNull("operatorIdHex"),
            eventDefinitionDigestHex = json.stringOrNull("eventDefinitionDigestHex"),
            validFrom = json.longOrNull("validFrom"),
            validUntil = json.longOrNull("validUntil"),
            unresolvedReason = json.stringOrNull("unresolvedReason"),
            acceptanceReceiptHex = json.stringOrNull("acceptanceReceiptHex"),
            terminalErrorCode = json.stringOrNull("terminalErrorCode"),
            observationDigestHex = json.stringOrNull("observationDigestHex"),
        )

        private fun JsonObject.stringOrNull(key: String): String? =
            this[key]?.takeUnless { it is JsonNull }?.jsonPrimitive?.content

        private fun JsonObject.longOrNull(key: String): Long? =
            this[key]?.takeUnless { it is JsonNull }?.jsonPrimitive?.long
    }
}
