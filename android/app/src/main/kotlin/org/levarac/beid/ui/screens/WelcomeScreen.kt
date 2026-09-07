package org.levarac.beid.ui.screens

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.tooling.preview.Preview
import org.levarac.beid.R
import org.levarac.beid.ui.designsystem.BeidPrimaryButton
import org.levarac.beid.ui.designsystem.BeidStateScreen
import org.levarac.beid.ui.designsystem.WelcomeMarkGlyph
import org.levarac.beid.ui.theme.BeidAppTheme
import org.levarac.beid.ui.theme.BeidTheme

object WelcomeScreenTestTags {
    const val GET_STARTED_BUTTON = "welcome_get_started_button"
}

/**
 * Screen 01: Welcome — mirrors iOS's `WelcomeView`
 * (`ios/Beid/Views/WelcomeView.swift`). Uses [BeidStateScreen]'s
 * `contentSlot` to render [WelcomeMarkGlyph] — iOS's Welcome header uses its
 * custom `welcome-mark` illustration (`assetImage`), not just its
 * `checkmark.seal.fill` SF Symbol fallback (`systemImage`), so a Material
 * icon was the wrong tier for this one screen (beid#338 correction; see
 * `Illustrations.kt`'s kdoc for the full reproduction-vs-import reasoning).
 * `BluetoothPermissionScreen`/`BluetoothOffScreen` stay on Material icons —
 * their iOS equivalents only ever pass `systemImage`, never `assetImage`.
 */
@Composable
fun WelcomeScreen(onGetStarted: () -> Unit) {
    BeidStateScreen(
        title = stringResource(R.string.welcome_title),
        message = stringResource(R.string.welcome_subtitle),
        tint = BeidTheme.colors.actionPrimary,
        contentSlot = { WelcomeMarkGlyph() },
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
    )
}

@Preview(showBackground = true)
@Composable
private fun WelcomeScreenPreview() {
    BeidAppTheme {
        WelcomeScreen(onGetStarted = {})
    }
}
