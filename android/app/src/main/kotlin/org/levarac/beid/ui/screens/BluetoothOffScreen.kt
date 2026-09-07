package org.levarac.beid.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.BluetoothDisabled
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.tooling.preview.Preview
import org.levarac.beid.R
import org.levarac.beid.ui.designsystem.BeidNumberedStepList
import org.levarac.beid.ui.designsystem.BeidPrimaryButton
import org.levarac.beid.ui.designsystem.BeidSecondaryButton
import org.levarac.beid.ui.designsystem.BeidStateScreen
import org.levarac.beid.ui.theme.BeidAppTheme
import org.levarac.beid.ui.theme.BeidSpacing
import org.levarac.beid.ui.theme.BeidTheme

object BluetoothOffScreenTestTags {
    const val OPEN_SETTINGS_BUTTON = "bluetooth_off_open_settings_button"
    const val TURNED_ON_BUTTON = "bluetooth_off_turned_on_button"
}

/**
 * Screen 03: Bluetooth-off recovery — mirrors iOS's `BluetoothOffView`
 * (`ios/Beid/Views/BluetoothOffView.swift`). Uses [BeidStateScreen]'s icon +
 * title + subtitle header now that `material-icons-extended` is a project
 * dependency (beid#338) — previously reproduced as plain Text/Column
 * without an icon roundel because no icon library was available.
 *
 * iOS applies its single `signalWarning` motif accent to the whole screen —
 * header glyph, step-list badges, and both buttons — via one ambient
 * `.tint()` (see `BluetoothOffView`'s trailing comment). Compose has no
 * ambient tint, so [BeidTheme.colors.signalWarning]/[BeidTheme.colors.labelOnWarning]
 * are passed explicitly to every warning-accented element here instead,
 * including the header icon's `tint`.
 */
@Composable
fun BluetoothOffScreen(onOpenSettings: () -> Unit, onTurnedOn: () -> Unit) {
    BeidStateScreen(
        icon = Icons.Filled.BluetoothDisabled,
        title = stringResource(R.string.bluetooth_off_title),
        message = stringResource(R.string.bluetooth_off_message),
        tint = BeidTheme.colors.signalWarning,
        accessory = {
            BeidNumberedStepList(
                steps = listOf(
                    stringResource(R.string.bluetooth_off_step_open_settings),
                    stringResource(R.string.bluetooth_off_step_tap_bluetooth),
                    stringResource(R.string.bluetooth_off_step_switch_on),
                ),
                badgeColor = BeidTheme.colors.signalWarning,
                labelColor = BeidTheme.colors.labelOnWarning,
            )
        },
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
    )
}

@Preview(showBackground = true)
@Composable
private fun BluetoothOffScreenPreview() {
    BeidAppTheme {
        BluetoothOffScreen(onOpenSettings = {}, onTurnedOn = {})
    }
}
