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
import org.levarac.beid.ui.designsystem.BeidNumberedStepList
import org.levarac.beid.ui.designsystem.BeidPrimaryButton
import org.levarac.beid.ui.designsystem.BeidScreen
import org.levarac.beid.ui.designsystem.BeidSecondaryButton
import org.levarac.beid.ui.theme.BeidAppTheme
import org.levarac.beid.ui.theme.BeidSpacing
import org.levarac.beid.ui.theme.BeidTheme

object BluetoothOffScreenTestTags {
    const val OPEN_SETTINGS_BUTTON = "bluetooth_off_open_settings_button"
    const val TURNED_ON_BUTTON = "bluetooth_off_turned_on_button"
}

/**
 * Screen 03: Bluetooth-off recovery — mirrors iOS's `BluetoothOffView`
 * (`ios/Beid/Views/BluetoothOffView.swift`). Header text reproduces
 * `BeidHeroHeader`'s layout as plain Text/Column without its icon roundel —
 * see [WelcomeScreen]'s kdoc for why.
 *
 * iOS applies its single `signalWarning` motif accent to the whole screen —
 * header glyph, step-list badges, and both buttons — via one ambient
 * `.tint()` (see `BluetoothOffView`'s trailing comment). Compose has no
 * ambient tint, so [BeidTheme.colors.signalWarning]/[BeidTheme.colors.labelOnWarning]
 * are passed explicitly to every warning-accented element here instead.
 */
@Composable
fun BluetoothOffScreen(onOpenSettings: () -> Unit, onTurnedOn: () -> Unit) {
    BeidScreen(
        footer = {
            Column(verticalArrangement = Arrangement.spacedBy(BeidSpacing.s)) {
                BeidPrimaryButton(
                    text = stringResource(R.string.bluetooth_off_open_settings_button),
                    containerColor = BeidTheme.colors.signalWarning,
                    contentColor = BeidTheme.colors.labelOnWarning,
                    onClick = onOpenSettings,
                    icon = null,
                    modifier = Modifier.testTag(BluetoothOffScreenTestTags.OPEN_SETTINGS_BUTTON),
                )
                BeidSecondaryButton(
                    text = stringResource(R.string.bluetooth_off_turned_on_button),
                    contentColor = BeidTheme.colors.signalWarning,
                    borderColor = BeidTheme.colors.signalWarning,
                    onClick = onTurnedOn,
                    modifier = Modifier.testTag(BluetoothOffScreenTestTags.TURNED_ON_BUTTON),
                )
            }
        },
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(BeidSpacing.l)) {
            Column(
                modifier = Modifier.fillMaxWidth(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(BeidSpacing.xs),
            ) {
                Text(
                    text = stringResource(R.string.bluetooth_off_title),
                    style = MaterialTheme.typography.headlineLarge,
                    color = BeidTheme.colors.textPrimary,
                    textAlign = TextAlign.Center,
                )
                Text(
                    text = stringResource(R.string.bluetooth_off_message),
                    style = MaterialTheme.typography.bodyLarge,
                    color = BeidTheme.colors.textSecondary,
                    textAlign = TextAlign.Center,
                )
            }

            BeidNumberedStepList(
                steps = listOf(
                    stringResource(R.string.bluetooth_off_step_open_settings),
                    stringResource(R.string.bluetooth_off_step_tap_bluetooth),
                    stringResource(R.string.bluetooth_off_step_switch_on),
                ),
                badgeColor = BeidTheme.colors.signalWarning,
                labelColor = BeidTheme.colors.labelOnWarning,
            )
        }
    }
}

@Preview(showBackground = true)
@Composable
private fun BluetoothOffScreenPreview() {
    BeidAppTheme {
        BluetoothOffScreen(onOpenSettings = {}, onTurnedOn = {})
    }
}
