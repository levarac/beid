package org.levarac.beid.ui.designsystem

import android.graphics.Bitmap
import androidx.activity.ComponentActivity
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import java.io.File
import org.junit.Assume.assumeTrue
import org.junit.BeforeClass
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.levarac.beid.shared.sigil.SigilGround
import org.levarac.beid.ui.theme.BeidAppTheme
import org.levarac.beid.ui.theme.BeidTheme
import org.levarac.beid.ui.theme.BeidSize
import org.levarac.beid.ui.theme.BeidSpacing
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Opt-in review PNGs of every Sigil placement (with the shared-built preview
 * fixture and with no data) and of the radar.
 *
 * Pass -Dbeid.screenshots.dir=<absolute-directory> to the TEST JVM, e.g.
 * through JAVA_TOOL_OPTIONS (Gradle does not forward arbitrary -D flags to
 * test workers). Skipped when the property is absent.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "w420dp-h900dp-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class SigilComponentsScreenshotTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    companion object {
        @JvmStatic @BeforeClass fun requireOptIn() {
            assumeTrue("Review screenshots are opt-in", !System.getProperty("beid.screenshots.dir").isNullOrBlank())
        }
    }

    private val tag = "shot"

    private val radarPeers = listOf(
        SensingRadarPeer("peer-a", null),
        SensingRadarPeer("peer-b", -45.0),
        SensingRadarPeer("peer-c", -60.0),
        SensingRadarPeer("peer-d", -75.0),
        SensingRadarPeer("peer-e", -95.0),
        SensingRadarPeer("peer-f", null),
    )

    private fun write(name: String, bitmap: Bitmap) {
        val first = bitmap.getPixel(0, 0)
        check((0 until bitmap.height).any { y -> (0 until bitmap.width).any { x -> bitmap.getPixel(x, y) != first } }) {
            "Screenshot must not be blank or a single color"
        }
        val directory = File(requireNotNull(System.getProperty("beid.screenshots.dir")))
        check(directory.isAbsolute) { "Screenshot directory must be absolute" }
        check(directory.isDirectory || directory.mkdirs())
        File(directory, "$name.png").outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        println("Screenshot: $name.png ${bitmap.width}x${bitmap.height}")
    }

    /** The component on its page colour, with a margin so the edge is visible. */
    private fun shot(name: String, onInk: Boolean, content: @Composable () -> Unit) {
        val bitmap = compose.captureNode(tag) {
            BeidAppTheme {
                val page = if (onInk) BeidTheme.colors.textPrimary else BeidTheme.colors.surfaceCanvas
                Box(Modifier.testTag(tag).background(page).padding(BeidSpacing.m)) { content() }
            }
        }
        write(name, bitmap)
    }

    private fun placement(placement: RecordSigilPlacement, withData: Boolean) {
        val suffix = if (withData) "sigil" else "ring"
        shot("placement-${placement.name}-$suffix", placement.page == RecordSigilSlot.Ground.Ink) {
            RecordSigilSlot(if (withData) SigilPreviewInputFactory.sample() else null, placement)
        }
    }

    @Test fun homeActiveCard() = RecordSigilPlacement.HomeActiveCard.let { placement(it, true); placement(it, false) }
    @Test fun homePastRow() = RecordSigilPlacement.HomePastRow.let { placement(it, true); placement(it, false) }
    @Test fun recordsGrid() = RecordSigilPlacement.RecordsGrid.let { placement(it, true); placement(it, false) }
    @Test fun sensingSealed() = RecordSigilPlacement.SensingSealed.let { placement(it, true); placement(it, false) }
    @Test fun proofCollected() = RecordSigilPlacement.ProofCollected.let { placement(it, true); placement(it, false) }
    @Test fun eventDetailRow() = RecordSigilPlacement.EventDetailRow.let { placement(it, true); placement(it, false) }
    @Test fun proofDetail() = RecordSigilPlacement.ProofDetail.let { placement(it, true); placement(it, false) }
    @Test fun reportDetailRow() = RecordSigilPlacement.ReportDetailRow.let { placement(it, true); placement(it, false) }

    @Test fun everyPlacementIsCaptured() {
        // Fails when a placement is added without a capture above.
        check(RecordSigilPlacement.entries.size == 8)
    }

    @Test fun welcomeHeroOutline() = shot("sigil-outline-200", onInk = false) {
        BeidSigil(SigilPreviewInputFactory.sample(), BeidSize.proofDetailSigil, SigilGround.OUTLINE)
    }

    @Test fun radarEmpty() = shot("radar-0-peers", onInk = true) { SensingRadar(emptyList(), 0, 0) }

    @Test fun radarWithEdges() = shot("radar-6-peers-edges", onInk = true) {
        SensingRadar(radarPeers, mutualDeviceCount = 0, observedWindowCount = 6, showsEdges = true)
    }

    @Test fun radarWithoutEdges() = shot("radar-6-peers-no-edges", onInk = true) {
        SensingRadar(radarPeers, mutualDeviceCount = 0, observedWindowCount = 6, showsEdges = false)
    }
}
