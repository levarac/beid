package org.levarac.beid.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bluetooth
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.tooling.preview.Preview
import org.levarac.beid.R
import org.levarac.beid.ui.designsystem.BeidHeroHeader
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
 * 3 benefit bullets with the same English copy. Uses [BeidHeroHeader]'s icon
 * + title + subtitle layout now that `material-icons-extended` is a project
 * dependency (beid#338) — the bullets themselves stay plain Text/Column
 * ([BeidBulletRow] is a separate, unrelated migration).
 *
 * Composed directly from [BeidScreen] + [BeidHeroHeader] rather than
 * [BeidStateScreen]: with the header icon roundel added, this screen's
 * header + 3-bullet panel no longer reliably fits above the footer button
 * on a short viewport, and [BeidStateScreen] gives its body no scroll
 * behavior. Wrapping just the body (not the footer) in `verticalScroll`
 * keeps the "Allow Bluetooth" CTA pinned and reachable regardless of
 * viewport height, the same scrollable-body-plus-fixed-footer shape
 * `EventJoinScreen` already uses. `Modifier.weight(1f, fill = false)` is
 * required alongside `verticalScroll` here — without a bounded height from
 * a sibling-aware `weight`, a plain `Column` measures a scrollable child
 * with unbounded height, so it never actually caps and the footer is
 * pushed off-screen instead of the body scrolling.
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
        Column(
            modifier = Modifier
                .weight(1f, fill = false)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(BeidSpacing.l),
        ) {
            BeidHeroHeader(
                icon = Icons.Filled.Bluetooth,
                title = stringResource(R.string.bluetooth_permission_title),
                subtitle = stringResource(R.string.bluetooth_permission_subtitle),
                tint = BeidTheme.colors.actionPrimary,
            )

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
