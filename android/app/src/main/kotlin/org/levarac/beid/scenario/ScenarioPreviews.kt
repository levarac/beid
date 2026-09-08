package org.levarac.beid.scenario

import androidx.compose.runtime.Composable
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.tooling.preview.PreviewParameter
import androidx.compose.ui.tooling.preview.PreviewParameterProvider
import org.levarac.beid.ui.screens.EventJoinContent
import org.levarac.beid.ui.screens.RecordsScreen
import org.levarac.beid.ui.theme.BeidAppTheme

/**
 * Feeds every [AndroidDemoScenario] into the previews below.
 *
 * The list is [AndroidDemoScenario.entries] rather than six names written out,
 * which is what beid#399 means by "adding a scenario makes it appear without
 * typing the list in a second place". Before this, each scenario had its own
 * hand-written `@Preview` function; adding a seventh scenario would have
 * compiled, run, and simply not appeared in the preview pane, with nothing to
 * notice it was missing.
 *
 * Internal rather than private so a test can pin it to [AndroidDemoScenario.entries].
 * Deriving the list is the guarantee; without a test, a later edit could quietly
 * replace it with a written-out list and every preview would still render.
 */
internal class ScenarioProvider : PreviewParameterProvider<AndroidDemoScenario> {
    override val values = AndroidDemoScenario.entries.asSequence()
}

/**
 * Every scenario on the Event Join surface. Since beid#363 these render
 * through [EventJoinContent] — the same stateless renderer `MainActivity`'s
 * DEBUG scenario host and the production screen use — so a preview shows what
 * the app shows rather than a separate legacy layout.
 */
@Preview(name = "Scenario — Event Join", showBackground = true)
@Composable
private fun ScenarioEventJoinPreview(
    @PreviewParameter(ScenarioProvider::class) scenario: AndroidDemoScenario,
) {
    BeidAppTheme {
        EventJoinContent(
            state = scenario.snapshot().eventJoinScreenState,
            onOpenAccount = {},
            onJoinNearbyEvent = {},
            onOpenSettings = {},
            onSimulateSignalLost = {},
            onResumeSensing = {},
        )
    }
}

/**
 * Every scenario on the Records surface.
 *
 * `zeroPeersForever` renders the empty list here, which is a real product
 * state rather than a gap in the fixture: that scenario observes nothing, so
 * it records nothing. The other five carry one row each.
 *
 * The detail screen has no preview here on purpose. [RecordsScreen] takes
 * `RecordListItem`, which [AndroidScenarioSnapshot] carries, while
 * `RecordDetailScreen` takes a `ProofRecord` — and the snapshot is forbidden
 * by `AndroidDemoScenarioTest` from having a `ProofRecord`-shaped member, so
 * that fixture data has no writable production input. Driving the detail
 * screen from a scenario would mean giving the snapshot exactly the type that
 * isolation exists to keep out. That is a design decision for whoever owns the
 * detail surface, not something to route around here.
 */
@Preview(name = "Scenario — Records", showBackground = true)
@Composable
private fun ScenarioRecordsPreview(
    @PreviewParameter(ScenarioProvider::class) scenario: AndroidDemoScenario,
) {
    BeidAppTheme {
        RecordsScreen(records = scenario.snapshot().records, onOpenDetail = {})
    }
}
