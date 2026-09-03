package org.levarac.beid.scenario

import androidx.compose.runtime.Composable
import androidx.compose.ui.tooling.preview.Preview
import org.levarac.beid.ui.screens.EventJoinScreen
import org.levarac.beid.ui.screens.RecordsScreen
import org.levarac.beid.ui.theme.BeidAppTheme

@Preview(name = "Scenario — crowd surge", showBackground = true)
@Composable
private fun CrowdSurgeEventJoinPreview() {
    val snapshot = AndroidDemoScenario.CrowdSurge.snapshot()
    BeidAppTheme {
        EventJoinScreen(
            state = snapshot.eventJoinScreenState,
            onEventCodeChanged = {},
            onSubmit = {},
            onOpenSettings = {},
            onOpenAccount = {},
            onSimulateSignalLost = {},
            onResumeSensing = {},
        )
    }
}

@Preview(name = "Scenario — long display names", showBackground = true)
@Composable
private fun LongDisplayNamesRecordsPreview() {
    BeidAppTheme {
        RecordsScreen(AndroidDemoScenario.LongDisplayNames.snapshot().records)
    }
}
