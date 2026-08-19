package org.levarac.beid.ui.designsystem

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import org.levarac.beid.ui.theme.BeidRadius
import org.levarac.beid.ui.theme.BeidSpacing

/**
 * Padded, `beidSurface`-backed content container — ports iOS's `BeidPanel`
 * (`ios/Beid/DesignSystem.swift`).
 */
@Composable
fun BeidPanel(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .beidSurface(cornerRadius = BeidRadius.card)
            .padding(BeidSpacing.m),
        content = content,
    )
}
