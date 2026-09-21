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
import org.levarac.beid.ui.designsystem.BeidPrimaryButton
import org.levarac.beid.ui.designsystem.BeidSecondaryButton
import org.levarac.beid.ui.designsystem.BeidStateScreen
import org.levarac.beid.ui.theme.BeidAppTheme
import org.levarac.beid.ui.theme.BeidSpacing
import org.levarac.beid.ui.theme.BeidTheme

object BluetoothDeniedScreenTestTags {
    const val OPEN_SETTINGS_BUTTON = "bluetooth_denied_open_settings_button"
    const val CHECK_AGAIN_BUTTON = "bluetooth_denied_check_again_button"
}

/** Permission-denied recovery. No event cards are rendered on this route. */
@Composable
fun BluetoothDeniedScreen(onOpenSettings: () -> Unit, onCheckAgain: () -> Unit) {
    BeidStateScreen(
        icon = Icons.Filled.BluetoothDisabled,
        title = stringResource(R.string.bluetooth_denied_title),
        message = stringResource(R.string.bluetooth_denied_message),
        tint = BeidTheme.colors.signalWarning,
        footer = {
            Column(verticalArrangement = Arrangement.spacedBy(BeidSpacing.s)) {
                BeidPrimaryButton(
                    text = stringResource(R.string.bluetooth_denied_open_settings_button),
                    containerColor = BeidTheme.colors.signalWarning,
                    contentColor = BeidTheme.colors.labelOnWarning,
                    onClick = onOpenSettings,
                    icon = null,
                    modifier = Modifier.testTag(BluetoothDeniedScreenTestTags.OPEN_SETTINGS_BUTTON),
                )
                BeidSecondaryButton(
                    text = stringResource(R.string.bluetooth_denied_check_again_button),
                    contentColor = BeidTheme.colors.signalWarning,
                    borderColor = BeidTheme.colors.signalWarning,
                    onClick = onCheckAgain,
                    modifier = Modifier.testTag(BluetoothDeniedScreenTestTags.CHECK_AGAIN_BUTTON),
                )
            }
        },
    )
}

@Preview(showBackground = true)
@Composable
private fun BluetoothDeniedScreenPreview() {
    BeidAppTheme {
        BluetoothDeniedScreen(onOpenSettings = {}, onCheckAgain = {})
    }
}
