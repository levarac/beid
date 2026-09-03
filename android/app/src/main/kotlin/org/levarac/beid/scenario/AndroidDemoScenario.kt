package org.levarac.beid.scenario

import java.time.Instant
import java.util.UUID
import org.levarac.beid.sensing.EventJoinUiState
import org.levarac.beid.sensing.ScanEventSession
import org.levarac.beid.sensing.ScanPhase
import org.levarac.beid.ui.screens.EventJoinScreenState
import org.levarac.beid.ui.screens.RecordListItem
import org.levarac.beid.ui.screens.RecordSignatureStatus

/**
 * Android's exact counterpart to the scenario vocabulary established by
 * iOS PR #288. The payload stays Android-native because it is presentation
 * data, not a cross-platform product decision or protocol value.
 */
enum class AndroidDemoScenario(val identifier: String) {
    ZeroPeersForever("zeroPeersForever"),
    CrowdSurge("crowdSurge"),
    LongDisplayNames("longDisplayNames"),
    UnidentifiedHeavy("unidentifiedHeavy"),
    SignalLostMidway("signalLostMidway"),
    AppReviewGolden("appReviewGolden"),
    ;

    companion object {
        fun named(identifier: String): AndroidDemoScenario? = entries.firstOrNull { it.identifier == identifier }
    }
}

/**
 * A closed, read-only UI snapshot. Its member types are deliberately limited
 * to screen models: there is no ProofRecord, store, signing, ledger,
 * submission, engine, or coordinator handle for a scenario to invoke.
 */
data class AndroidScenarioSnapshot(
    val scenario: AndroidDemoScenario,
    val eventJoinScreenState: EventJoinScreenState,
    val records: List<RecordListItem>,
)

/** The only two application roots MainActivity may select. */
sealed interface AndroidDataSource {
    data object RealBle : AndroidDataSource
    data class ReadOnlyScenario(val scenario: AndroidDemoScenario) : AndroidDataSource
}

/**
 * Resolves the Android equivalent of `-beid-demo-scenario <name>`.
 * Missing/unknown values and every non-Debug call remain on real BLE.
 */
fun selectAndroidDataSource(requestedScenario: String?, scenariosEnabled: Boolean): AndroidDataSource {
    if (!scenariosEnabled) return AndroidDataSource.RealBle
    val scenario = requestedScenario?.let(AndroidDemoScenario::named) ?: return AndroidDataSource.RealBle
    return AndroidDataSource.ReadOnlyScenario(scenario)
}

fun AndroidDemoScenario.snapshot(): AndroidScenarioSnapshot {
    val eventCode = when (this) {
        AndroidDemoScenario.ZeroPeersForever -> "ZERO-PEERS"
        AndroidDemoScenario.CrowdSurge -> "CROWD-SURGE-2026"
        AndroidDemoScenario.LongDisplayNames ->
            "The International Gathering for Open, Verifiable and Durable Local Participation 🌏"
        AndroidDemoScenario.UnidentifiedHeavy -> "UNIDENTIFIED-HEAVY"
        AndroidDemoScenario.SignalLostMidway -> "SIGNAL-LOST-MIDWAY"
        AndroidDemoScenario.AppReviewGolden -> "APP-REVIEW-GOLDEN"
    }
    val peerCount = when (this) {
        AndroidDemoScenario.ZeroPeersForever -> 0
        AndroidDemoScenario.CrowdSurge -> 40
        AndroidDemoScenario.LongDisplayNames -> 8
        AndroidDemoScenario.UnidentifiedHeavy -> 3
        AndroidDemoScenario.SignalLostMidway -> 12
        AndroidDemoScenario.AppReviewGolden -> 5
    }
    val session = ScanEventSession(eventCode)
    val phase = when (this) {
        AndroidDemoScenario.ZeroPeersForever -> ScanPhase.Sensing
        AndroidDemoScenario.SignalLostMidway -> ScanPhase.SignalLost(session, peerCount)
        else -> ScanPhase.Recording(session, peerCount)
    }
    val records = if (this == AndroidDemoScenario.ZeroPeersForever) {
        emptyList()
    } else {
        listOf(
            RecordListItem(
                id = UUID.nameUUIDFromBytes("beid-demo-$identifier".toByteArray()),
                eventLabel = eventCode,
                createdAt = Instant.parse("2026-08-28T00:00:00Z"),
                peersVerified = peerCount,
                signatureStatus = when (this) {
                    AndroidDemoScenario.AppReviewGolden -> RecordSignatureStatus.SelfProof
                    AndroidDemoScenario.LongDisplayNames -> RecordSignatureStatus.Bound
                    else -> RecordSignatureStatus.NotSigned
                },
            ),
        )
    }
    return AndroidScenarioSnapshot(
        scenario = this,
        eventJoinScreenState = EventJoinScreenState(
            eventCode = eventCode,
            sessionState = EventJoinUiState.Sensing(phase),
        ),
        records = records,
    )
}
