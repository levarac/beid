package org.levarac.beid.ui.designsystem

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import org.levarac.beid.ui.theme.BeidSpacing
import org.levarac.beid.ui.theme.BeidTheme

/**
 * Screen-level container — `surfaceCanvas` background, content slot + an
 * optional footer slot, vertically centered, page-margin horizontal
 * padding. Ports iOS's `BeidScreen` (`ios/Beid/DesignSystem.swift`),
 * material-fallback path only — no glass-group wrapping, since Android has
 * no Liquid Glass equivalent (see `BeidGlassGroup`'s omission note in this
 * package's kdoc / the PR report).
 */
@Composable
fun BeidScreen(
    modifier: Modifier = Modifier,
    footer: (@Composable () -> Unit)? = null,
    content: @Composable () -> Unit,
) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .background(BeidTheme.colors.surfaceCanvas)
            .padding(horizontal = BeidSpacing.pageMargin),
        verticalArrangement = Arrangement.spacedBy(BeidSpacing.l, Alignment.CenterVertically),
    ) {
        content()
        footer?.invoke()
    }
}
