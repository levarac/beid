package org.levarac.beid.lab

import android.os.Bundle
import android.widget.TextView
import org.levarac.beid.MainActivity
import org.levarac.beid.persistence.SubmissionRecordStore
import org.levarac.parallax.submission.SubmissionErrorCode

/** Lab launcher; production MainActivity remains the coordinator owner. */
class LabMainActivity : MainActivity() {
    private var labBootstrap: LabControlBootstrap? = null

    /** Read-only, bounded projection of durable submission metadata for Lab snapshots. */
    private fun labRecordMetadata(): List<LabRecordMetadata> =
        SubmissionRecordStore(SubmissionRecordStore.defaultFile(filesDir)).records.map { record ->
            LabRecordMetadata(
                windowId = record.windowId,
                eventId = record.eventIdHex,
                observationDigest = record.observationDigestHex,
                status = when {
                    record.acceptanceReceiptHex != null -> "accepted"
                    record.terminalErrorCode != null -> "terminal_failure"
                    record.unresolvedReason != null -> "unresolved"
                    else -> "prepared"
                },
                receiptStored = record.acceptanceReceiptHex != null,
                terminalError = record.terminalErrorCode
                    ?.takeIf { code -> SubmissionErrorCode.values().any { it.wireName == code } },
            )
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val identity = runCatching {
            LabControlIdentity(
                runId = intent.getStringExtra("run_id").orEmpty(),
                role = intent.getStringExtra("role").orEmpty(),
                deviceId = intent.getStringExtra("device_id").orEmpty(),
                generation = intent.getIntExtra("generation", -1),
                token = intent.getStringExtra("token").orEmpty(),
                protocolVersion = intent.getIntExtra("protocol_version", -1),
            )
        }.getOrElse {
            setContentView(TextView(this).apply { text = "Lab bootstrap refused: ${it.message}" })
            return
        }
        val brokerUrl = intent.getStringExtra("broker_url").orEmpty()
        if (brokerUrl.isBlank()) {
            setContentView(TextView(this).apply { text = "Lab bootstrap refused: lab broker is not configured" })
            return
        }
        val bootstrap = LabControlBootstrap(
            identity = identity,
            brokerUrl = brokerUrl,
            broker = OkHttpLabWebSocketClient(),
            productionState = ::labReadOnlyState,
            nearbyCandidates = ::labNearbyCandidateSelectors,
            joinNearbyEvent = ::labJoinNearbyEvent,
            records = ::labRecordMetadata,
        )
        labBootstrap = bootstrap
        val result = bootstrap.start()
        if (result.isFailure) {
            setContentView(TextView(this).apply { text = "Lab bootstrap refused: ${result.exceptionOrNull()?.message}" })
        }
    }

    override fun onDestroy() {
        labBootstrap?.stop()
        labBootstrap = null
        super.onDestroy()
    }
}
