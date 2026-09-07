package org.levarac.beid.sensing

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Two absences the relay work depends on (beid#367).
 *
 * The issue asks for these to be pinned rather than merely intended, and the
 * only honest way to pin an absence is to read the source. A behavioural test
 * can show that today's code path signs nothing and that no scenario arms a
 * radio; it cannot stop someone adding a proof write to the verifier, or
 * handing a coordinator to the scenario root, next month. That is the
 * regression worth preventing.
 *
 * Deliberately blunt: each check fails on a name, and the fix is either to
 * move the new work out of the named file or to argue here why a term on the
 * list is not what it looks like.
 *
 * **These lists are mirrored in iOS's `ParticipantRelayIsolationTests` and
 * must stay identical.** A name dropped from one side is a hole on that
 * platform only, which is the hardest kind of gap to notice: the suite still
 * passes everywhere someone thinks to look.
 */
class ParticipantRelayIsolationTest {
    @Test
    fun `the relay sources name nothing from the recording, signing or submission paths`() {
        assertSourcesAvoid(RELAY_SOURCES, RECORDING_SIGNING_SUBMISSION, "relay")
    }

    /**
     * The other direction, and the reason it is a separate list: the relay
     * sources legitimately name the relay-arming and discovery symbols, while
     * the scenario sources must never name any of them. A scenario that could
     * seed discovery or arm the relay would put fabricated candidates on a
     * real radio.
     */
    @Test
    fun `the scenario sources name nothing that seeds discovery or arms the relay`() {
        assertSourcesAvoid(SCENARIO_SOURCES, DISCOVERY_SEEDING_AND_RELAY_ARMING, "scenario")
    }

    /**
     * The scenario root holds no engine, so nothing rendered from a scenario
     * can join, seed discovery, or arm the relay. iOS states the same property
     * inside `SensingCoordinator.startParticipantRelay()`; Android's version
     * is structural, and this is what keeps it that way.
     *
     * Reads the function body rather than the file: `MainActivity` as a whole
     * legitimately constructs an [EventJoinCoordinator] on the real-BLE
     * branch, and the invariant is about which branch gets one.
     */
    @Test
    fun `the scenario branch of the activity root constructs no engine`() {
        val activity = File("src/main/kotlin/org/levarac/beid/MainActivity.kt")
        assertTrue("MainActivity.kt is missing", activity.exists())
        val body = activity.readText().functionBody("private fun startReadOnlyScenario(")

        for (name in listOf("EventJoinCoordinator", "EventJoinEngine", "BarnardEngine")) {
            assertTrue(
                "startReadOnlyScenario references $name; a scenario must never reach a radio",
                !body.contains(name),
            )
        }
    }

    /**
     * The text between a declaration's opening brace and its matching close.
     * Brace counting is enough here: the function it reads has no string
     * literal or comment containing an unbalanced brace, and a test that
     * silently read the wrong range would fail loudly on the names above
     * rather than pass by accident.
     */
    private fun String.functionBody(declaration: String): String {
        val start = indexOf(declaration)
        require(start >= 0) { "declaration not found: $declaration" }
        val open = indexOf('{', start)
        var depth = 0
        for (index in open until length) {
            when (this[index]) {
                '{' -> depth += 1
                '}' -> {
                    depth -= 1
                    if (depth == 0) return substring(open, index + 1)
                }
            }
        }
        throw IllegalStateException("unbalanced braces after: $declaration")
    }

    private fun assertSourcesAvoid(paths: List<String>, forbidden: List<String>, role: String) {
        for (path in paths) {
            val file = File(path)
            assertTrue("$role source is missing: $path", file.exists())
            val source = file.readText()
            for (name in forbidden) {
                assertTrue(
                    "$path references $name, which a $role source must not reach into",
                    !source.contains(name),
                )
            }
        }
    }

    private companion object {
        val RELAY_SOURCES = listOf(
            "src/main/kotlin/org/levarac/beid/sensing/ParticipantRelayVerifier.kt",
            "src/main/kotlin/org/levarac/beid/sensing/ParticipantRelayDecision.kt",
        )

        val SCENARIO_SOURCES = listOf(
            "src/main/kotlin/org/levarac/beid/scenario/AndroidDemoScenario.kt",
            "src/main/kotlin/org/levarac/beid/scenario/ScenarioPreviews.kt",
        )

        /**
         * Names owned by the paths relay is fenced off from: the observation
         * ledger, self-proof signing, and report submission. Keep identical to
         * iOS's list of the same name.
         */
        val RECORDING_SIGNING_SUBMISSION = listOf(
            "SelfProof",
            "ProofRecord",
            "SensingCryptography",
            "WindowObservation",
            "WindowAccumulator",
            "WindowReport",
            "UnsentWindowLedger",
            "BindingRecord",
            "ReportSubmission",
            "AggregationRuntime",
            "ScanPhase",
        )

        /**
         * Names that seed the discovery store or arm the participant relay. A
         * scenario reaching any of these would put fabricated candidates in
         * front of the join gate, or fabricated bytes on a radio. Keep
         * identical to iOS's list of the same name.
         */
        val DISCOVERY_SEEDING_AND_RELAY_ARMING = listOf(
            "recordNearbyEventRadioSelfVerified",
            "completeNearbyEventRegistryResolution",
            "applyNearbyEventRegistryAgreement",
            "configureParticipantRelay",
            "setParticipantRelayVerifier",
        )
    }
}
