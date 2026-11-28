package org.levarac.beid.ui.screens

import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.ComposeContentTestRule
import kotlin.test.assertTrue

/**
 * DESIGN.md §15 claim scope (beid#389): visible copy describes observations,
 * explicit joining and foreground sensing. It must not claim proof, promise
 * automatic or background operation, or say there is nothing to do.
 */
internal val FORBIDDEN_OBSERVATION_COPY = listOf(
    "proof",
    "prove",
    "automatically",
    "no codes",
    "no taps",
    "nothing to tap",
    "background",
)

/** Fails if any rendered text node contains a forbidden §15 phrase. */
internal fun ComposeContentTestRule.assertNoForbiddenObservationCopy() {
    for (phrase in FORBIDDEN_OBSERVATION_COPY) {
        val hits = onAllNodes(hasText(phrase, substring = true, ignoreCase = true), useUnmergedTree = true)
            .fetchSemanticsNodes()
            .map { node -> node.config.getOrNull(SemanticsProperties.Text)?.joinToString(" ") }
        assertTrue(hits.isEmpty(), "forbidden copy \"$phrase\" rendered in: $hits")
    }
}
