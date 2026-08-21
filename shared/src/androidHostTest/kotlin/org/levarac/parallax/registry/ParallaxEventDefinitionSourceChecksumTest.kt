package org.levarac.parallax.registry

import java.io.File
import org.junit.Assume
import org.junit.Test
import org.levarac.parallax.observation.readVectorResource
import kotlin.test.assertEquals

/**
 * When the sibling Parallax checkout is present, compare the copied resources to its live files.
 * The common test keeps the pinned hashes for CI; this host test catches a stale local copy before
 * a developer can accidentally update the Kotlin decoder against a different protocol revision.
 */
class ParallaxEventDefinitionSourceChecksumTest {
    @Test
    fun copiedVectorsAndCddlMatchTheParallaxCheckoutWhenAvailable() {
        val root = File(
            System.getenv("PARALLAX_REPO") ?: "/Users/kenichi/Repository/Levarac/parallax",
        )
        Assume.assumeTrue("Parallax checkout is not available", root.isDirectory)

        assertResourceMatchesSource(
            resourcePath = "vectors/positive/event-definition-v1.json",
            source = root.resolve("protocol/vectors/positive/event-definition-v1.json"),
        )
        assertResourceMatchesSource(
            resourcePath = "vectors/negative/event-definition-v1.json",
            source = root.resolve("protocol/vectors/negative/event-definition-v1.json"),
        )
        assertResourceMatchesSource(
            resourcePath = "canonical/event-definition-v1.cddl",
            source = root.resolve("protocol/cddl/event-definition-v1.cddl"),
        )
        assertSourceChecksum(
            source = root.resolve("protocol/reference/js/src/wire-identifiers.ts"),
            expectedSha256 = "0x43f09463989086a0b44e3213f495d7e8b06dc14bf0a4e69f830d2e788cdffc61",
        )
    }

    private fun assertResourceMatchesSource(resourcePath: String, source: File) {
        Assume.assumeTrue("Parallax source file is not available: ${source.path}", source.isFile)
        val copied = readVectorResource(resourcePath).encodeToByteArray()
        val canonical = source.readBytes()
        assertEquals(
            Sha256.digest(canonical).toPrefixedHex(),
            Sha256.digest(copied).toPrefixedHex(),
            "copied resource drifted from ${source.path}",
        )
    }

    private fun assertSourceChecksum(source: File, expectedSha256: String) {
        Assume.assumeTrue("Parallax source file is not available: ${source.path}", source.isFile)
        assertEquals(expectedSha256, Sha256.digest(source.readBytes()).toPrefixedHex(), source.path)
    }
}
