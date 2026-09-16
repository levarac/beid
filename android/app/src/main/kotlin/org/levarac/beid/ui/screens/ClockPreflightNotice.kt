package org.levarac.beid.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.tooling.preview.Preview
import org.levarac.beid.R
import org.levarac.beid.shared.clock.ClockPreflightState
import org.levarac.beid.ui.designsystem.BeidPanel
import org.levarac.beid.ui.designsystem.BeidSecondaryButton
import org.levarac.beid.ui.theme.BeidAppTheme
import org.levarac.beid.ui.theme.BeidSpacing
import org.levarac.beid.ui.theme.BeidTheme

/**
 * beid#464: tells the participant when this device's clock is off, or when it
 * could not be checked. The verdict comes from the shared preflight; this only
 * chooses the words.
 *
 * Exhaustive with no `else`, so a state added to shared must be given copy
 * here. [ClockPreflightState.WITHIN_TOLERANCE] and a still-running first
 * check (`null`) render nothing.
 */
@Composable
fun ClockPreflightNotice(state: ClockPreflightState?, onRetry: () -> Unit) {
    val (titleRes, bodyRes) = when (state) {
        null, ClockPreflightState.WITHIN_TOLERANCE -> return
        ClockPreflightState.OVER_TOLERANCE ->
            R.string.clock_preflight_over_title to R.string.clock_preflight_over_body
        ClockPreflightState.UNDETERMINABLE ->
            R.string.clock_preflight_undeterminable_title to R.string.clock_preflight_undeterminable_body
    }
    BeidPanel(modifier = Modifier.testTag(EventJoinScreenTestTags.CLOCK_PREFLIGHT_NOTICE)) {
        Column(verticalArrangement = Arrangement.spacedBy(BeidSpacing.s)) {
            Text(
                text = stringResource(titleRes),
                style = MaterialTheme.typography.titleMedium,
                color = BeidTheme.colors.textPrimary,
                modifier = Modifier.semantics {
                    heading()
                    liveRegion = LiveRegionMode.Polite
                },
            )
            Text(
                text = stringResource(bodyRes),
                style = MaterialTheme.typography.bodyMedium,
                color = BeidTheme.colors.textSecondary,
            )
            BeidSecondaryButton(
                text = stringResource(R.string.clock_preflight_retry),
                contentColor = BeidTheme.colors.actionPrimary,
                borderColor = BeidTheme.colors.strokeHairline,
                onClick = onRetry,
                modifier = Modifier.testTag(EventJoinScreenTestTags.CLOCK_PREFLIGHT_RETRY),
            )
        }
    }
}

@Preview(name = "Clock preflight — over tolerance", showBackground = true)
@Composable
private fun ClockPreflightNoticeOverPreview() {
    BeidAppTheme { ClockPreflightNotice(ClockPreflightState.OVER_TOLERANCE, onRetry = {}) }
}

@Preview(name = "Clock preflight — undeterminable", showBackground = true)
@Composable
private fun ClockPreflightNoticeUndeterminablePreview() {
    BeidAppTheme { ClockPreflightNotice(ClockPreflightState.UNDETERMINABLE, onRetry = {}) }
}
