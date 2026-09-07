package org.levarac.beid.scenario

import androidx.compose.runtime.Composable
import androidx.compose.ui.tooling.preview.Preview
import org.levarac.beid.ui.screens.EventJoinContent
import org.levarac.beid.ui.screens.RecordsScreen
import org.levarac.beid.ui.theme.BeidAppTheme

/**
 * Compose previews of the read-only scenarios, one per [AndroidDemoScenario]
 * on the Event Join surface. Since beid#363 they render through
 * [EventJoinContent] — the same stateless renderer `MainActivity`'s DEBUG
 * launch-argument scenario host and the production screen use — so a preview
 * shows what the app shows instead of a separate legacy layout.
 */
@Composable
private fun ScenarioEventJoinPreview(scenario: AndroidDemoScenario) {
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

@Preview(name = "Scenario — zero peers forever", showBackground = true)
@Composable
private fun ZeroPeersForeverEventJoinPreview() {
    ScenarioEventJoinPreview(AndroidDemoScenario.ZeroPeersForever)
}

@Preview(name = "Scenario — crowd surge", showBackground = true)
@Composable
private fun CrowdSurgeEventJoinPreview() {
    ScenarioEventJoinPreview(AndroidDemoScenario.CrowdSurge)
}

@Preview(name = "Scenario — long display names", showBackground = true)
@Composable
private fun LongDisplayNamesEventJoinPreview() {
    ScenarioEventJoinPreview(AndroidDemoScenario.LongDisplayNames)
}

@Preview(name = "Scenario — unidentified heavy", showBackground = true)
@Composable
private fun UnidentifiedHeavyEventJoinPreview() {
    ScenarioEventJoinPreview(AndroidDemoScenario.UnidentifiedHeavy)
}

@Preview(name = "Scenario — signal lost midway", showBackground = true)
@Composable
private fun SignalLostMidwayEventJoinPreview() {
    ScenarioEventJoinPreview(AndroidDemoScenario.SignalLostMidway)
}

@Preview(name = "Scenario — App Review golden", showBackground = true)
@Composable
private fun AppReviewGoldenEventJoinPreview() {
    ScenarioEventJoinPreview(AndroidDemoScenario.AppReviewGolden)
}

@Preview(name = "Scenario — long display names (records)", showBackground = true)
@Composable
private fun LongDisplayNamesRecordsPreview() {
    BeidAppTheme {
        RecordsScreen(AndroidDemoScenario.LongDisplayNames.snapshot().records)
    }
}
