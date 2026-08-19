package org.levarac.beid.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.tooling.preview.Preview
import org.levarac.beid.R
import org.levarac.beid.ui.designsystem.BeidPrimaryButton
import org.levarac.beid.ui.designsystem.BeidScreen
import org.levarac.beid.ui.theme.BeidAppTheme
import org.levarac.beid.ui.theme.BeidSpacing
import org.levarac.beid.ui.theme.BeidTheme

object WelcomeScreenTestTags {
    const val GET_STARTED_BUTTON = "welcome_get_started_button"
}

/**
 * Screen 01: Welcome — mirrors iOS's `WelcomeView`
 * (`ios/Beid/Views/WelcomeView.swift`). Title/subtitle reproduce
 * `BeidHeroHeader`'s centered text layout as plain Text/Column, without its
 * icon roundel — this scaffold has no material-icons-core/-extended
 * dependency (see `TestIcon.kt`'s kdoc), so `BeidHeroHeader` itself is not
 * used here, matching how `EventJoinScreen` already avoids the icon-required
 * design-system components.
 */
@Composable
fun WelcomeScreen(onGetStarted: () -> Unit) {
    BeidScreen(
        footer = {
            BeidPrimaryButton(
                text = stringResource(R.string.welcome_get_started),
                containerColor = BeidTheme.colors.actionPrimary,
                contentColor = BeidTheme.colors.surfaceCanvas,
                onClick = onGetStarted,
                icon = null,
                modifier = Modifier.testTag(WelcomeScreenTestTags.GET_STARTED_BUTTON),
            )
        },
    ) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(BeidSpacing.xs),
        ) {
            Text(
                text = stringResource(R.string.welcome_title),
                style = MaterialTheme.typography.headlineLarge,
                color = BeidTheme.colors.textPrimary,
                textAlign = TextAlign.Center,
            )
            Text(
                text = stringResource(R.string.welcome_subtitle),
                style = MaterialTheme.typography.bodyLarge,
                color = BeidTheme.colors.textSecondary,
                textAlign = TextAlign.Center,
            )
        }
    }
}

@Preview(showBackground = true)
@Composable
private fun WelcomeScreenPreview() {
    BeidAppTheme {
        WelcomeScreen(onGetStarted = {})
    }
}
