package org.levarac.beid.scenario

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue
import org.levarac.beid.persistence.ProofRecord

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
}
