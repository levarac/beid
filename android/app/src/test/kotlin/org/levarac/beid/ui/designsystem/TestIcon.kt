package org.levarac.beid.ui.designsystem

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.path
import androidx.compose.ui.unit.dp

/**
 * Minimal hand-built [ImageVector] fixture for design-system component
 * tests. Components in this package take `icon: ImageVector` as a
 * caller-supplied parameter and don't reach into any icon library
 * themselves — `material-icons-extended` (beid#338) is a dependency of the
 * production screens that choose real icons, not of this package — so
 * tests build their own trivial vector instead of reaching for
 * `Icons.Filled.*`.
 */
internal val testIcon: ImageVector by lazy {
    ImageVector.Builder(
        name = "TestIcon",
        defaultWidth = 24.dp,
        defaultHeight = 24.dp,
        viewportWidth = 24f,
        viewportHeight = 24f,
    ).apply {
        path(fill = SolidColor(Color.Black)) {
            moveTo(4f, 4f)
            lineTo(20f, 4f)
            lineTo(20f, 20f)
            lineTo(4f, 20f)
            close()
        }
    }.build()
}
