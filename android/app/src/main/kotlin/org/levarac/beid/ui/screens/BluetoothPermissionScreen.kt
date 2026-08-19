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
import org.levarac.beid.ui.designsystem.BeidPanel
import org.levarac.beid.ui.designsystem.BeidPrimaryButton
import org.levarac.beid.ui.designsystem.BeidScreen
import org.levarac.beid.ui.theme.BeidAppTheme
import org.levarac.beid.ui.theme.BeidSpacing
import org.levarac.beid.ui.theme.BeidTheme

object BluetoothPermissionScreenTestTags {
    const val ALLOW_BUTTON = "bluetooth_permission_allow_button"
}

private data class Bullet(val titleRes: Int, val subtitleRes: Int)

private val bullets = listOf(
    Bullet(
        R.string.bluetooth_permission_bullet_events_find_you_title,
        R.string.bluetooth_permission_bullet_events_find_you_subtitle,
    ),
    Bullet(
        R.string.bluetooth_permission_bullet_private_title,
        R.string.bluetooth_permission_bullet_private_subtitle,
    ),
    Bullet(
        R.string.bluetooth_permission_bullet_zero_effort_title,
        R.string.bluetooth_permission_bullet_zero_effort_subtitle,
    ),
)

/**
 * Screen 02: Bluetooth-permission explanation — mirrors iOS's
 * `BluetoothPermissionView` (`ios/Beid/Views/BluetoothPermissionView.swift`),
 * 3 benefit bullets with the same English copy. Header text and each
 * bullet's title+subtitle reproduce `BeidHeroHeader`'s/`BeidBulletRow`'s
 * *text* layout as plain Text/Column, without their icon roundels — see
 * [WelcomeScreen]'s kdoc for why (no material-icons dependency in this
 * scaffold).
 */
@Composable
fun BluetoothPermissionScreen(onAllowBluetooth: () -> Unit) {
    BeidScreen(
        footer = {
            Column(verticalArrangement = Arrangement.spacedBy(BeidSpacing.s)) {
                BeidPrimaryButton(
                    text = stringResource(R.string.bluetooth_permission_allow_button),
                    containerColor = BeidTheme.colors.actionPrimary,
                    contentColor = BeidTheme.colors.surfaceCanvas,
                    onClick = onAllowBluetooth,
                    icon = null,
                    modifier = Modifier.testTag(BluetoothPermissionScreenTestTags.ALLOW_BUTTON),
                )
                Text(
                    text = stringResource(R.string.bluetooth_permission_settings_note),
                    style = MaterialTheme.typography.labelSmall,
                    color = BeidTheme.colors.textSecondary,
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
                    text = stringResource(R.string.bluetooth_permission_title),
                    style = MaterialTheme.typography.headlineLarge,
                    color = BeidTheme.colors.textPrimary,
                    textAlign = TextAlign.Center,
                )
                Text(
                    text = stringResource(R.string.bluetooth_permission_subtitle),
                    style = MaterialTheme.typography.bodyLarge,
                    color = BeidTheme.colors.textSecondary,
                    textAlign = TextAlign.Center,
                )
            }

            BeidPanel {
                Column(verticalArrangement = Arrangement.spacedBy(BeidSpacing.m)) {
                    bullets.forEach { bullet ->
                        Column(verticalArrangement = Arrangement.spacedBy(BeidSpacing.xs)) {
                            Text(
                                text = stringResource(bullet.titleRes),
                                style = MaterialTheme.typography.titleMedium,
                                color = BeidTheme.colors.textPrimary,
                            )
                            Text(
                                text = stringResource(bullet.subtitleRes),
                                style = MaterialTheme.typography.labelSmall,
                                color = BeidTheme.colors.textSecondary,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Preview(showBackground = true)
@Composable
private fun BluetoothPermissionScreenPreview() {
    BeidAppTheme {
        BluetoothPermissionScreen(onAllowBluetooth = {})
    }
}
