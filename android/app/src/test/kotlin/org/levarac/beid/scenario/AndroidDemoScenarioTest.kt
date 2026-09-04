package org.levarac.beid.scenario

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue
import org.levarac.beid.persistence.ProofRecord
import org.levarac.beid.sensing.ScanPhase

class AndroidDemoScenarioTest {
    @Test
    fun everyRequiredScenarioIsEnumerableByItsExactSharedIdentifier() {
        assertEquals(
            listOf(
                "zeroPeersForever",
                "crowdSurge",
                "longDisplayNames",
                "unidentifiedHeavy",
                "signalLostMidway",
                "appReviewGolden",
            ),
            AndroidDemoScenario.entries.map(AndroidDemoScenario::identifier),
        )
    }

    @Test
    fun debugLaunchExtraSelectsOnlyAKnownReadOnlyScenario() {
        val selection = selectAndroidDataSource(
            requestedScenario = "crowdSurge",
            scenariosEnabled = true,
        )

        assertIs<AndroidDataSource.ReadOnlyScenario>(selection)
        assertEquals(AndroidDemoScenario.CrowdSurge, selection.scenario)
        assertEquals(AndroidScenarioSurface.EventJoin, selection.surface)
    }

    @Test
    fun debugLaunchCanSelectTheReadOnlyRecordsSurface() {
        val selection = selectAndroidDataSource(
            requestedScenario = "longDisplayNames",
            requestedSurface = "records",
            scenariosEnabled = true,
        )

        assertIs<AndroidDataSource.ReadOnlyScenario>(selection)
        assertEquals(AndroidDemoScenario.LongDisplayNames, selection.scenario)
        assertEquals(AndroidScenarioSurface.Records, selection.surface)
    }

    @Test
    fun missingOrUnknownDebugLaunchExtraKeepsTheRealBlePath() {
        assertEquals(
            AndroidDataSource.RealBle,
            selectAndroidDataSource(requestedScenario = null, scenariosEnabled = true),
        )
        assertEquals(
            AndroidDataSource.RealBle,
            selectAndroidDataSource(requestedScenario = "not-a-scenario", scenariosEnabled = true),
        )
        assertEquals(
            AndroidDataSource.RealBle,
            selectAndroidDataSource(
                requestedScenario = "crowdSurge",
                requestedSurface = "not-a-surface",
                scenariosEnabled = true,
            ),
        )
    }

    @Test
    fun nonDebugBuildAlwaysKeepsTheRealBlePathEvenForAKnownScenario() {
        assertEquals(
            AndroidDataSource.RealBle,
            selectAndroidDataSource(
                requestedScenario = "appReviewGolden",
                scenariosEnabled = false,
            ),
        )
    }

    @Test
    fun everyScenarioProducesOnlyReadOnlyScreenModels() {
        AndroidDemoScenario.entries.forEach { scenario ->
            val snapshot = scenario.snapshot()

            assertEquals(scenario, snapshot.scenario)
            assertFalse(
                snapshot.records.any { ProofRecord::class.java.isInstance(it) },
                "${scenario.identifier} must never manufacture a ProofRecord that ProofRecordStore can write",
            )
        }
    }

    @Test
    fun scenarioSnapshotHasNoWritableOrEffectfulMemberTypes() {
        val forbiddenTypeNames = listOf(
            "ProofRecord",
            "ProofRecordStore",
            "SelfProofRecord",
            "BindingRecord",
            "UnsentWindowLedger",
            "SensingCryptography",
            "Submission",
            "EventJoinCoordinator",
            "EventJoinEngine",
        )

        val memberTypes = AndroidScenarioSnapshot::class.java.declaredFields.map { it.genericType.typeName }
        forbiddenTypeNames.forEach { forbidden ->
            assertTrue(
                memberTypes.none { forbidden in it },
                "scenario snapshot must not expose a $forbidden-shaped input: $memberTypes",
            )
        }
    }

    @Test
    fun signalLostScenarioPlaysOrderedPhasesAndWaitsForResumeBeforeItsTerminalFrame() {
        val playback = AndroidDemoScenario.SignalLostMidway.playback()

        assertEquals(
            listOf(
                ScanPhase.Sensing::class,
                ScanPhase.EventFound::class,
                ScanPhase.Recording::class,
                ScanPhase.SignalLost::class,
                ScanPhase.Recording::class,
            ),
            playback.frames.map { it.snapshot.eventJoinScreenState.scanPhase::class },
        )
        assertEquals(AndroidScenarioAdvance.Automatic, playback.frames[0].advance)
        assertEquals(AndroidScenarioAdvance.Resume, playback.frames[3].advance)
        assertNull(playback.frames.last().advance)
        assertEquals(12, playback.frames[3].snapshot.eventJoinScreenState.peersVerified)
        assertEquals(13, playback.frames.last().snapshot.eventJoinScreenState.peersVerified)
    }

    @Test
    fun appReviewGoldenPlaybackAdvancesInOrderAndTerminatesAtItsGoldenSnapshot() {
        val playback = AndroidDemoScenario.AppReviewGolden.playback()

        assertEquals(
            listOf(
                ScanPhase.Sensing::class,
                ScanPhase.EventFound::class,
                ScanPhase.Recording::class,
                ScanPhase.Recording::class,
            ),
            playback.frames.map { it.snapshot.eventJoinScreenState.scanPhase::class },
        )
        assertTrue(playback.frames.dropLast(1).all { it.advance == AndroidScenarioAdvance.Automatic })
        assertNull(playback.frames.last().advance)
        assertEquals(AndroidDemoScenario.AppReviewGolden.snapshot(), playback.frames.last().snapshot)
    }
}

private val org.levarac.beid.ui.screens.EventJoinScreenState.scanPhase: ScanPhase
    get() = (sessionState as org.levarac.beid.sensing.EventJoinUiState.Sensing).phase

private val org.levarac.beid.ui.screens.EventJoinScreenState.peersVerified: Int
    get() = when (val phase = scanPhase) {
        is ScanPhase.Recording -> phase.peersVerified
        is ScanPhase.SignalLost -> phase.peersVerified
        else -> 0
    }
