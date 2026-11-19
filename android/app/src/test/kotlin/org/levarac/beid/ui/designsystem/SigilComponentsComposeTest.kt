package org.levarac.beid.ui.designsystem

import android.graphics.Bitmap
import androidx.activity.ComponentActivity
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertContentDescriptionEquals
import androidx.compose.ui.test.assertHeightIsEqualTo
import androidx.compose.ui.test.assertWidthIsEqualTo
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.levarac.beid.shared.sigil.SigilGround
import org.levarac.beid.shared.sigil.SigilInput
import org.levarac.beid.shared.sigil.addSigilPresence
import org.levarac.beid.shared.sigil.createSigilInput
import org.levarac.beid.ui.theme.BeidAppTheme
import org.levarac.beid.ui.theme.BeidTheme
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * The composables' accessibility contract and a few rendered pixels.
 *
 * The pixel checks exist for one reason the pure tests cannot cover: the
 * layout is in dp and Canvas draws in px, so a missing density transform
 * would draw a correct-looking Sigil at a third of its size here (xxhdpi).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "w420dp-h900dp-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class SigilComponentsComposeTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    private val tag = "component"
    private val ink = 0xFF0B0B0F.toInt()
    private val bg = 0xFFFFFFFF.toInt()
    private val line = 0xFFECECF1.toInt()

    /** Two detected peers over three windows; nothing mutual, as on a device. */
    private fun deviceInput(): SigilInput = createSigilInput(3).also {
        assertTrue(addSigilPresence(it, "peer-a", 0, 1))
        assertTrue(addSigilPresence(it, "peer-a", 1, 1))
        assertTrue(addSigilPresence(it, "peer-b", 2, 1))
    }

    private fun SemanticsNodeInteraction.isHidden(): Boolean =
        fetchSemanticsNode().config.contains(SemanticsProperties.HideFromAccessibility)

    private fun SemanticsNodeInteraction.description(): List<String>? =
        fetchSemanticsNode().config.getOrNull(SemanticsProperties.ContentDescription)

    @Test
    fun beidSigilSpeaksItsSummaryAndOccupiesItsSize() {
        compose.setContent {
            BeidAppTheme { BeidSigil(deviceInput(), 200.dp, SigilGround.DISC, Modifier.testTag(tag)) }
        }
        compose.onNodeWithTag(tag)
            .assertWidthIsEqualTo(200.dp)
            .assertHeightIsEqualTo(200.dp)
            .assertContentDescriptionEquals("0 mutual, 2 detected, window 3")
        assertFalse(compose.onNodeWithTag(tag).isHidden())
    }

    @Test
    fun aDeviceRecordSpeaksTheRecordSummary() {
        compose.setContent {
            BeidAppTheme {
                BeidSigil(deviceInput(), 200.dp, SigilGround.DISC, Modifier.testTag(tag), isDeviceRecord = true)
            }
        }
        compose.onNodeWithTag(tag)
            .assertContentDescriptionEquals("Devices heard: 2. Window 3. Mutual check not available yet.")
    }

    @Test
    fun aSigilThatDrewNothingIsHidden() {
        compose.setContent {
            BeidAppTheme { BeidSigil(deviceInput(), 1.dp, SigilGround.DISC, Modifier.testTag(tag)) }
        }
        assertTrue(compose.onNodeWithTag(tag, useUnmergedTree = true).isHidden())
    }

    @Test
    fun aRecordWithoutDataIsAHiddenRingAtThePlacementSize() {
        compose.setContent {
            BeidAppTheme { RecordSigilSlot(null, RecordSigilPlacement.RecordsGrid, Modifier.testTag(tag)) }
        }
        val node = compose.onNodeWithTag(tag, useUnmergedTree = true)
        node.assertWidthIsEqualTo(104.dp).assertHeightIsEqualTo(104.dp)
        assertTrue(node.isHidden())
        assertNull(node.description())
    }

    @Test
    fun aRecordWithDataDrawsItsSigilAtThePlacementSize() {
        compose.setContent {
            BeidAppTheme {
                RecordSigilSlot(deviceInput(), RecordSigilPlacement.ProofDetail, Modifier.testTag(tag), isDeviceRecord = true)
            }
        }
        compose.onNodeWithTag(tag)
            .assertWidthIsEqualTo(200.dp)
            .assertContentDescriptionEquals("Devices heard: 2. Window 3. Mutual check not available yet.")
        assertFalse(compose.onNodeWithTag(tag).isHidden())
    }

    @Test
    fun theRadarSpeaksOnlyTheCountAndNoIdentifier() {
        val peers = listOf(
            SensingRadarPeer("private-peer-identifier", null),
            SensingRadarPeer("peer-b", -55.0),
            SensingRadarPeer("peer-c", -90.0),
        )
        compose.setContent {
            BeidAppTheme { SensingRadar(peers, mutualDeviceCount = 1, observedWindowCount = 4, modifier = Modifier.testTag(tag)) }
        }
        compose.onNodeWithTag(tag)
            .assertWidthIsEqualTo(362.dp)
            .assertHeightIsEqualTo(362.dp)
            .assertContentDescriptionEquals("3 devices heard")
        for (peer in peers) {
            compose.onAllNodesWithText(peer.id, substring = true, useUnmergedTree = true).assertCountEquals(0)
            compose.onAllNodesWithContentDescription(peer.id, substring = true, useUnmergedTree = true).assertCountEquals(0)
        }
    }

    @Test
    fun theRadarCarriesTheIosAccessibilityIdentifierAsItsDefaultTag() {
        compose.setContent { BeidAppTheme { SensingRadar(emptyList(), 0, 0) } }
        compose.onNodeWithTag(SensingRadar.TEST_TAG).assertContentDescriptionEquals("0 devices heard")
        assertEquals("sensing.radar", SensingRadar.TEST_TAG)
    }

    // region Pixels

    private fun Bitmap.at(xDp: Double, yDp: Double): Int =
        getPixel((xDp * 3).toInt(), (yDp * 3).toInt())

    @Test
    fun theDiscFillsThePlacementSizeInPixels() {
        val bitmap = compose.captureNode(tag) {
            BeidAppTheme { RecordSigilSlot(deviceInput(), RecordSigilPlacement.ProofDetail, Modifier.testTag(tag)) }
        }
        assertEquals(600, bitmap.width)
        assertEquals(600, bitmap.height)
        assertEquals("disc reaches the top edge", ink, bitmap.at(100.0, 2.0))
        assertEquals("disc reaches the right edge", ink, bitmap.at(198.0, 100.0))
        assertEquals("disc is a circle, the corner is clear", 0, bitmap.at(1.0, 1.0))
        assertEquals("centre dot on the disc is bg", bg, bitmap.at(100.0, 100.0))
    }

    @Test
    fun theNeutralRingIsAHairlineInsideTheFrame() {
        val bitmap = compose.captureNode(tag) {
            BeidAppTheme { RecordSigilSlot(null, RecordSigilPlacement.ProofDetail, Modifier.testTag(tag)) }
        }
        assertEquals(600, bitmap.width)
        assertEquals(line, bitmap.at(100.0, 0.5))
        assertEquals(0, bitmap.at(100.0, 100.0))
    }

    @Test
    fun marksOnAnInkPageArePaintedBg() {
        val bitmap = compose.captureNode(tag) {
            BeidAppTheme {
                Box(Modifier.testTag(tag).background(BeidTheme.colors.textPrimary)) {
                    RecordSigilSlot(deviceInput(), RecordSigilPlacement.HomeActiveCard)
                }
            }
        }
        assertEquals(252, bitmap.width)
        assertEquals("centre dot", bg, bitmap.at(42.0, 42.0))
        assertEquals("page", ink, bitmap.at(1.0, 1.0))
    }

    @Test
    fun theRadarDrawsItsCoreAtTheFieldScale() {
        val bitmap = compose.captureNode(tag) {
            BeidAppTheme { SensingRadar(emptyList(), 0, 0, modifier = Modifier.testTag(tag)) }
        }
        assertEquals(1086, bitmap.width)
        assertEquals("ink field", ink, bitmap.at(2.0, 2.0))
        assertEquals("centre dot", ink, bitmap.at(181.0, 181.0))
        assertEquals("white core", bg, bitmap.at(181.0 + 10, 181.0))
        assertEquals("ink separation", ink, bitmap.at(181.0 + 22, 181.0))
        assertNotEquals("inner ring hairline", ink, bitmap.at(181.0, 181.0 - 133.22 / 2))
    }

    // endregion
}
