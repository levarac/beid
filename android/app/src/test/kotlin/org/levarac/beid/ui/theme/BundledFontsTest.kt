package org.levarac.beid.ui.theme

import android.content.Context
import android.graphics.Paint
import android.graphics.Typeface
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontSynthesis
import androidx.compose.ui.text.font.createFontFamilyResolver
import androidx.core.content.res.ResourcesCompat
import androidx.test.core.app.ApplicationProvider
import java.io.File
import java.security.MessageDigest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNotSame
import org.junit.Test
import org.junit.runner.RunWith
import org.levarac.beid.R
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * The eight bundled faces load at runtime and are the iOS files.
 *
 * Native graphics mode makes Robolectric parse each font file with the real
 * platform text stack, so a width measured with it is the face's own
 * metrics. A non-null [Typeface] alone proves little — a font that failed
 * to parse can still come back as a fallback — so each face must also
 * measure differently from the default face and from every other bundled
 * face (the five Display cuts differ only in their `opsz` instance).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class BundledFontsTest {

    private val context: Context = ApplicationProvider.getApplicationContext()

    /** Android resource → the iOS file it must be byte-identical to. */
    private val bundled = linkedMapOf(
        R.font.bricolage_grotesque_display60_extrabold to "BricolageGrotesque-Display60ExtraBold.ttf",
        R.font.bricolage_grotesque_display52_extrabold to "BricolageGrotesque-Display52ExtraBold.ttf",
        R.font.bricolage_grotesque_display46_extrabold to "BricolageGrotesque-Display46ExtraBold.ttf",
        R.font.bricolage_grotesque_display40_extrabold to "BricolageGrotesque-Display40ExtraBold.ttf",
        R.font.bricolage_grotesque_display34_extrabold to "BricolageGrotesque-Display34ExtraBold.ttf",
        R.font.dm_sans_bold to "DMSans-Bold.ttf",
        R.font.dm_sans_regular to "DMSans-Regular.ttf",
        R.font.dm_mono_medium to "DMMono-Medium.ttf",
    )

    private val sample = "Events 0123456789 ETHTOKYO"

    private fun widthOf(typeface: Typeface, features: String? = null, text: String = sample): Float =
        Paint().apply {
            this.typeface = typeface
            textSize = 100f
            fontFeatureSettings = features
        }.measureText(text)

    @Test
    fun everyBundledFontLoadsAsItsOwnFace() {
        val defaultWidth = widthOf(Typeface.DEFAULT)
        val widths = bundled.keys.associateWith { id ->
            val typeface = ResourcesCompat.getFont(context, id)
            assertNotNull("R.font $id did not load", typeface)
            assertNotSame(Typeface.DEFAULT, typeface)
            widthOf(typeface!!).also { assertNotEquals("R.font $id measures as the default face", defaultWidth, it) }
        }
        assertEquals("two bundled faces measure identically: $widths", bundled.size, widths.values.toSet().size)
    }

    @Test
    fun composeResolvesEveryLibraryStyleToItsBundledFace() {
        val resolver = createFontFamilyResolver(context)
        val library = BeidFont.Library
        val styles = listOf(
            library.display60, library.display52, library.display46, library.displayNumber40,
            library.displayAddress34, library.title19, library.title17, library.title16, library.title15,
            library.body15, library.body13, library.labelMono11, library.labelMono10, library.labelMono9,
            library.labelMono10Tight, library.labelMono11Time, library.labelMono13Value,
        )
        for (style in styles) {
            val resolved = resolver.resolve(
                style.textStyle.fontFamily,
                style.textStyle.fontWeight!!,
                FontStyle.Normal,
                FontSynthesis.All,
            ).value as Typeface
            val direct = ResourcesCompat.getFont(context, style.fontRes)!!
            assertEquals("${style.fontRes}", widthOf(direct), widthOf(resolved))
        }
    }

    @Test
    fun displayNumber40DigitsAreTabular() {
        val face = ResourcesCompat.getFont(context, R.font.bricolage_grotesque_display40_extrabold)!!
        val digitWidths = (0..9).map { widthOf(face, "tnum", it.toString()) }.toSet()
        assertEquals("tnum digit widths: $digitWidths", 1, digitWidths.size)
    }

    @Test
    fun bundledFontsAreByteIdenticalToTheIosFonts() {
        for ((id, iosName) in bundled) {
            val android = context.resources.openRawResource(id).use { it.readBytes() }
            assertArrayEquals(iosName, sha256(iosFont(iosName).readBytes()), sha256(android))
        }
    }

    @Test
    fun oflLicencesShipInAssetsByteIdenticalToTheIosCopies() {
        for (name in listOf("OFL-BricolageGrotesque.txt", "OFL-DMSans.txt", "OFL-DMMono.txt")) {
            val shipped = context.assets.open("licenses/$name").use { it.readBytes() }
            assertArrayEquals(name, sha256(iosFont(name).readBytes()), sha256(shipped))
        }
    }

    /** Unit tests run with the module directory (android/app) as the working directory. */
    private fun iosFont(name: String) = File("../../ios/Beid/DesignSystem/Fonts/$name")

    private fun sha256(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)
}
