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
     * A brace inside a comment or a string must not end the extracted range.
     *
     * The first version of the helper below counted braces over raw text,
     * which had exactly this hole: a stray `}` in a comment truncated the
     * range, and any coordinator added after that point would have passed the
     * test silently. The failure would have been invisible -- a green test
     * asserting almost nothing -- so the helper is exercised on a fixture
     * rather than trusted.
     */
    @Test
    fun `the body reader is not fooled by braces in comments or strings`() {
        val fixture = """
            private fun startReadOnlyScenario(dataSource: Any) {
                // a closing brace in a comment: }
                /* and in a block comment: } */
                val text = "and in a string: }"
                render(text)
            }

            private fun somethingElse() {
                EventJoinCoordinator(this)
            }
        """.trimIndent()

        val body = fixture.functionBody("private fun startReadOnlyScenario(", indent = "")

        assertTrue("the range stopped early: $body", body.contains("render(text)"))
        assertTrue(
            "the range ran past the function: $body",
            !body.contains("EventJoinCoordinator"),
        )
    }

    /**
     * The text between a declaration's opening brace and its matching close.
     *
     * Two independent guards, because one is not enough. Comments and string
     * literals are blanked before any brace is counted, so a brace inside
     * either cannot be mistaken for code. Then the closing brace is required
     * to sit on a line that is exactly [indent] plus `}` -- the function's own
     * closing line -- so a range that ended early, at some deeper nesting
     * level, fails rather than quietly returning a fragment.
     *
     * Blanking preserves length and newlines, so every index still refers to
     * the same character in the original text and the returned body is the
     * real source, comments and all.
     */
    private fun String.functionBody(declaration: String, indent: String = "    "): String {
        val scannable = blankCommentsAndStrings()
        val start = scannable.indexOf(declaration)
        require(start >= 0) { "declaration not found: $declaration" }
        val open = scannable.indexOf('{', start)
        var depth = 0
        for (index in open until length) {
            when (scannable[index]) {
                '{' -> depth += 1
                '}' -> {
                    depth -= 1
                    if (depth == 0) {
                        val lineStart = lastIndexOf('\n', index).let { if (it < 0) 0 else it + 1 }
                        val closingLine = substring(lineStart, index + 1)
                        check(closingLine == "$indent}") {
                            "the body ended at \"$closingLine\" rather than the function's own " +
                                "closing line, so the extracted range is not the whole function"
                        }
                        return substring(open, index + 1)
                    }
                }
            }
        }
        throw IllegalStateException("unbalanced braces after: $declaration")
    }

    /**
     * The same text with every comment and string literal replaced by spaces,
     * keeping length and line breaks so indices stay aligned with the original.
     */
    private fun String.blankCommentsAndStrings(): String {
        val out = toCharArray()
        var index = 0
        fun blankUntil(end: Int) {
            for (position in index until minOf(end, length)) {
                if (out[position] != '\n') out[position] = ' '
            }
            index = minOf(end, length)
        }
        while (index < length) {
            val rest = length - index
            when {
                rest >= 2 && this[index] == '/' && this[index + 1] == '/' -> {
                    val end = indexOf('\n', index).let { if (it < 0) length else it }
                    blankUntil(end)
                }
                rest >= 2 && this[index] == '/' && this[index + 1] == '*' -> {
                    val end = indexOf("*/", index).let { if (it < 0) length else it + 2 }
                    blankUntil(end)
                }
                rest >= 3 && startsWith("\"\"\"", index) -> {
                    val end = indexOf("\"\"\"", index + 3).let { if (it < 0) length else it + 3 }
                    blankUntil(end)
                }
                this[index] == '"' -> {
                    var end = index + 1
                    while (end < length && this[end] != '"' && this[end] != '\n') {
                        end += if (this[end] == '\\') 2 else 1
                    }
                    blankUntil(minOf(end + 1, length))
                }
                else -> index += 1
            }
        }
        return String(out)
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
