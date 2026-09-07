package org.levarac.beid.sensing

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Relay must never touch recording, signing, or submission (beid#367).
 *
 * The issue asks for this to be pinned rather than merely intended, and the
 * only honest way to pin an absence is to read the source. A behavioural test
 * can show that today's code path does not sign anything; it cannot stop
 * someone adding a proof write to the verifier next month, which is exactly
 * the regression worth preventing.
 *
 * Kept deliberately blunt: it fails loudly on a name, and the fix is either to
 * move the new work out of the relay files or to argue here why a term on this
 * list is not what it looks like.
 */
class ParticipantRelayIsolationTest {
    @Test
    fun `the relay files name nothing from the recording, signing or submission paths`() {
        for (path in RELAY_SOURCES) {
            val file = File(path)
            assertTrue("relay source is missing: $path", file.exists())
            val source = file.readText()
            for (forbidden in FORBIDDEN) {
                assertTrue(
                    "$path references $forbidden; relay must not reach into recording, " +
                        "signing or submission",
                    !source.contains(forbidden),
                )
            }
        }
    }

    private companion object {
        val RELAY_SOURCES = listOf(
            "src/main/kotlin/org/levarac/beid/sensing/ParticipantRelayVerifier.kt",
            "src/main/kotlin/org/levarac/beid/sensing/ParticipantRelayDecision.kt",
        )

        /**
         * Type and concept names owned by the paths relay is fenced off from:
         * the observation ledger, self-proof signing, and report submission.
         */
        val FORBIDDEN = listOf(
            "SelfProof",
            "ProofRecord",
            "SensingCryptography",
            "WindowObservation",
            "WindowAccumulator",
            "UnsentWindowLedger",
            "BindingRecord",
            "ReportSubmission",
            "ScanPhase",
        )
    }
}
