package org.levarac.beid.ui.designsystem

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import org.levarac.beid.ui.theme.BeidSpacing

/**
 * The composed "icon → title → body → optional accessory → footer CTA"
 * pattern shared by state screens — ports iOS's `BeidStatusLayout`
 * (`ios/Beid/DesignSystem.swift`), used by Welcome, BluetoothPermission,
 * BluetoothOff, and SignalLost. Built from [BeidScreen] + [BeidHeroHeader]
 * plus an accessory slot and a footer slot.
 */
@Composable
fun BeidStateScreen(
    icon: ImageVector,
    title: String,
    message: String,
    tint: Color,
    modifier: Modifier = Modifier,
    contentSlot: (@Composable () -> Unit)? = null,
    accessory: (@Composable () -> Unit)? = null,
    footer: (@Composable () -> Unit)? = null,
) {
    BeidScreen(modifier = modifier, footer = footer) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(BeidSpacing.l),
        ) {
            BeidHeroHeader(
                icon = icon,
                title = title,
                subtitle = message,
                tint = tint,
                contentSlot = contentSlot,
            )
            accessory?.invoke()
        }
    }
}
