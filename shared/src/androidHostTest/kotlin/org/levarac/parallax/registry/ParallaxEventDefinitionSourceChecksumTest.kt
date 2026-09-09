package org.levarac.parallax.registry

import java.io.File
import org.junit.Test
import org.junit.AssumptionViolatedException
import org.junit.Rule
import org.junit.rules.TemporaryFolder
import org.levarac.parallax.observation.readVectorResource
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.fail

// Parallax main verified on 2026-09-08. To bump, fetch Parallax main, review the
// vector/CDDL/wire-identifier changes, and replace this full commit ID in the same
// change that reconciles the vendored resources/checksums. Never use a moving branch.
private const val EXPECTED_PARALLAX_REF = "5215991b440db8e8bdc6279eee30affa0c532023"

/**
 * Sibling directory consulted when [PARALLAX_REPO_ENV] says nothing: `../parallax`
 * beside the beid repository root.
 *
 * Resolved from [REPO_ROOT_PROPERTY], which `shared/build.gradle.kts` computes from
 * this module's PROJECT directory. Deliberately not the working directory: a cwd
 * resolution would make the answer depend on where the wrapper happened to be
 * invoked, which is the dependence this evening removed from the Parallax side.
 * It was previously an absolute path under one developer's home, which tied the
 * gate to a single machine -- on a Linux runner it could not be found even in
 * principle.
 */
private const val DEFAULT_PARALLAX_DIRECTORY_NAME = "parallax"

private const val REPO_ROOT_PROPERTY = "beid.repoRoot"

private const val PARALLAX_REPO_ENV = "PARALLAX_REPO"

private const val VENDORED_RESOURCE_ROOT = "shared/src/commonTest/resources"

private const val VENDORED_RESOURCE_SENTINEL = "canonical/event-definition-v1.cddl"

private data class VendoredResourceMapping(
    val resourcePath: String,
    val sourcePath: String,
)

/**
 * Android-host-only checkout discovery. This deliberately reads the repository's
 * source-tree directory via [REPO_ROOT_PROPERTY]; it is not a portable commonTest
 * resource enumerator. Kotlin/Native uses the explicit processedResources Copy
 * tasks documented in shared/build.gradle.kts instead of this JVM disk layout.
 */
private fun discoverVendoredResourceMappings(repoRoot: File?): List<VendoredResourceMapping> {
    val resourceRoot = repoRoot?.resolve(VENDORED_RESOURCE_ROOT)
    val resourcePaths = if (resourceRoot?.isDirectory == true) {
        resourceRoot.walkTopDown()
            .filter(File::isFile)
            .map { it.relativeTo(resourceRoot).invariantSeparatorsPath }
            .sorted()
            .toList()
    } else {
        emptyList()
    }
    return requireMappedVendoredResources(resourcePaths)
}

private fun requireMappedVendoredResources(
    resourcePaths: List<String>,
): List<VendoredResourceMapping> {
    assertTrue(
        resourcePaths.isNotEmpty(),
        "No regular vendored resources were discovered; expected a non-empty set containing " +
            "sentinel '$VENDORED_RESOURCE_SENTINEL'.",
    )
    assertTrue(
        VENDORED_RESOURCE_SENTINEL in resourcePaths,
        "Vendored resource discovery did not contain sentinel '$VENDORED_RESOURCE_SENTINEL'.",
    )
    return resourcePaths.map(::mapVendoredResource)
}

private fun mapVendoredResource(resourcePath: String): VendoredResourceMapping {
    val segments = resourcePath.split('/')
    val sourcePath = when {
        segments.size == 3 && segments[0] == "vectors" &&
            segments[1].isNotEmpty() && segments[2].isNotEmpty() ->
            "protocol/vectors/${segments[1]}/${segments[2]}"
        segments.size == 2 && segments[0] == "canonical" &&
            segments[1].removeSuffix(".cddl").isNotEmpty() && segments[1].endsWith(".cddl") ->
            "protocol/cddl/${segments[1]}"
        else -> fail(
            "Vendored resource '$resourcePath' has no Parallax source mapping. " +
                "Expected vectors/<bucket>/<name> or canonical/<name>.cddl.",
        )
    }
    return VendoredResourceMapping(resourcePath, sourcePath)
}

/**
 * Where to look, and whether an absent checkout is allowed to skip.
 *
 * The distinction is the whole point of beid#403's second finding. An absent
 * checkout has two utterly different causes and the old code could not tell
 * them apart: CI genuinely has no Parallax checkout and never will, which is a
 * legitimate absence; and someone who SET [PARALLAX_REPO_ENV] to a path that is
 * not there has misconfigured it -- or is silencing this check on purpose.
 * Both produced the identical silent skip.
 *
 * That mattered because THE CONVENTION THIS TEAM ADOPTED TO KEEP UNRELATED
 * TESTS GREEN WAS THE DELIBERATE SILENCING: every agent was instructed to point
 * [PARALLAX_REPO_ENV] at a nonexistent path on every Gradle invocation, which
 * disabled the one test in this repository that compares our vendored bytes to
 * real upstream bytes. A guard that cannot distinguish a legitimate absence
 * from a deliberate silencing will eventually be silenced and read as passing.
 *
 * So: unset means fall back and skip if the sibling is missing, which keeps CI
 * working untouched. Set means the operator asserted a checkout, and anything
 * wrong with it fails loudly. beid#415 is the same idea one level up -- a
 * standing home in PR CI, cloning Parallax at the expected ref, so this stops
 * depending on anyone remembering to point a variable anywhere.
 */
private class ParallaxCheckout(val root: File, val maySkipWhenAbsent: Boolean)

/**
 * Null means CANNOT TELL: nothing was configured and the repo root is unknown, so
 * there is no place to look. That is a third state, distinct from "a checkout is
 * absent" and from "a configured path is wrong", and it is reported as its own
 * skip reason rather than being folded into the first.
 */
private fun parallaxCheckout(configured: String?, repoRoot: File?): ParallaxCheckout? =
    when {
        configured != null -> ParallaxCheckout(File(configured), maySkipWhenAbsent = false)
        repoRoot == null -> null
        else -> ParallaxCheckout(
            repoRoot.resolveSibling(DEFAULT_PARALLAX_DIRECTORY_NAME),
            maySkipWhenAbsent = true,
        )
    }

private fun configuredRepoRoot(): File? = System.getProperty(REPO_ROOT_PROPERTY)?.let(::File)

/**
 * An absent checkout skips this optional cross-repo check ONLY when nobody asked for
 * one -- see [ParallaxCheckout] for why that qualifier is the whole point. An existing
 * checkout must be at the explicit pinned commit; read committed blobs so dirty files
 * cannot change the oracle. Common tests independently check the vendored hashes on
 * every machine.
 */
class ParallaxEventDefinitionSourceChecksumTest {
    @get:Rule
    val temporaryFolder = TemporaryFolder()

    @Test
    fun everyVendoredResourceHasAParallaxMapping() {
        val mappings = discoverVendoredResourceMappings(configuredRepoRoot())
        assertEquals(
            mappings.sortedBy { it.resourcePath },
            mappings,
            "vendored resource mappings must have deterministic relative-path order",
        )
    }

    @Test
    fun vendoredResourceMappingRulesDeriveParallaxPaths() {
        assertEquals(
            VendoredResourceMapping(
                resourcePath = "vectors/example-bucket/example.json",
                sourcePath = "protocol/vectors/example-bucket/example.json",
            ),
            mapVendoredResource("vectors/example-bucket/example.json"),
        )
        assertEquals(
            VendoredResourceMapping(
                resourcePath = "canonical/example.cddl",
                sourcePath = "protocol/cddl/example.cddl",
            ),
            mapVendoredResource("canonical/example.cddl"),
        )
    }

    @Test
    fun anUnknownVendoredResourcePathFailsLoudly() {
        val unknown = "unmapped/new-resource.txt"
        val failure = assertFailsWith<AssertionError> {
            requireMappedVendoredResources(listOf(VENDORED_RESOURCE_SENTINEL, unknown))
        }

        assertTrue(failure.message.orEmpty().contains(unknown))
        assertTrue(failure.message.orEmpty().contains("has no Parallax source mapping"))
    }

    @Test
    fun emptyVendoredResourceDiscoveryFailsClosed() {
        val failure = assertFailsWith<AssertionError> {
            requireMappedVendoredResources(emptyList())
        }

        assertTrue(failure.message.orEmpty().contains("No regular vendored resources were discovered"))
        assertTrue(failure.message.orEmpty().contains(VENDORED_RESOURCE_SENTINEL))
    }

    @Test
    fun wrongCheckoutRefFailsBeforeComparingFiles() {
        val root = temporaryFolder.newFolder("unrelated checkout")
        fixtureGit(root, "init", "--initial-branch=feature/unrelated")
        fixtureGit(root, "commit", "--allow-empty", "-m", "expected revision")
        val expected = fixtureGit(root, "rev-parse", "HEAD")
        fixtureGit(root, "commit", "--allow-empty", "-m", "unrelated revision")
        val current = fixtureGit(root, "rev-parse", "HEAD")

        val failure = assertFailsWith<AssertionError> { assertExpectedCheckout(root, expected, maySkipWhenAbsent = true) }
        val message = failure.message.orEmpty()
        for (detail in listOf(root.absolutePath, "feature/unrelated", current, expected)) {
            assertTrue(message.contains(detail), "Missing '$detail' in: $message")
        }
    }

    @Test
    fun missingCheckoutRemainsSkippable() {
        val root = File(temporaryFolder.root, "missing")
        assertFailsWith<AssumptionViolatedException> {
            assertExpectedCheckout(root, "a".repeat(40), maySkipWhenAbsent = true)
        }
    }

    @Test
    fun existingNonGitDirectoryFailsInsteadOfSkipping() {
        val root = temporaryFolder.newFolder("not a repository")
        val expected = "a".repeat(40)
        val failure = assertFailsWith<AssertionError> { assertExpectedCheckout(root, expected, maySkipWhenAbsent = true) }
        assertTrue(failure.message.orEmpty().contains(root.absolutePath))
        assertTrue(failure.message.orEmpty().contains(expected))
    }

    @Test
    fun expectedCommitIsAcceptedWithDetachedHead() {
        val root = temporaryFolder.newFolder("pinned checkout")
        fixtureGit(root, "init", "--initial-branch=main")
        fixtureGit(root, "commit", "--allow-empty", "-m", "expected revision")
        val expected = fixtureGit(root, "rev-parse", "HEAD")
        fixtureGit(root, "checkout", "--detach", expected)
        assertExpectedCheckout(root, expected, maySkipWhenAbsent = true)
    }

    private fun fixtureGit(root: File, vararg args: String): String {
        val process = ProcessBuilder(
            listOf("git", "-C", root.absolutePath, "-c", "user.name=Checksum test",
                "-c", "user.email=checksum@example.invalid", "-c", "commit.gpgsign=false",
                "-c", "core.hooksPath=/dev/null") + args,
        ).redirectErrorStream(true).start()
        val output = process.inputStream.bufferedReader().use { it.readText() }.trim()
        assertEquals(0, process.waitFor(), output)
        return output
    }

    private fun assertExpectedCheckout(
        root: File,
        expectedRef: String,
        maySkipWhenAbsent: Boolean,
    ) {
        if (!root.exists()) {
            if (!maySkipWhenAbsent) {
                fail(
                    "$PARALLAX_REPO_ENV is set to ${root.absolutePath}, which does not exist. " +
                        "A configured checkout that is not there is a misconfiguration, not a " +
                        "reason to skip: unset $PARALLAX_REPO_ENV to skip, or point it at a " +
                        "checkout of $expectedRef.",
                )
            }
            throw AssumptionViolatedException(
                "Parallax checkout is not available: ${root.absolutePath}",
            )
        }
        fun metadata(vararg args: String): String = runCatching {
            gitBytes(root, *args).decodeToString().trim()
        }.getOrDefault("<unavailable>")

        val branch = metadata("rev-parse", "--abbrev-ref", "HEAD")
        val commit = metadata("rev-parse", "--verify", "HEAD^{commit}")
        val topLevel = metadata("rev-parse", "--show-toplevel")
        val message = "Parallax checkout ${root.absolutePath}: current branch=$branch " +
            "(HEAD means detached), commit=$commit; expected ref=$expectedRef. " +
            "Point PARALLAX_REPO at a checkout of the expected commit. " +
            "Refusing to compare resources from an unexpected checkout."
        assertTrue(root.isDirectory && File(topLevel).canonicalFile == root.canonicalFile, message)
        assertEquals(expectedRef, commit, message)
    }

    private fun gitBytes(root: File, vararg args: String): ByteArray {
        val process = ProcessBuilder(listOf("git", "-C", root.absolutePath) + args)
            .redirectErrorStream(true).start()
        val output = process.inputStream.use { it.readBytes() }
        assertEquals(0, process.waitFor(), "git ${args.joinToString(" ")} at ${root.absolutePath}: " +
            output.decodeToString())
        return output
    }

    private fun readPinnedSource(root: File, sourcePath: String, expectedRef: String): ByteArray =
        gitBytes(root, "show", "$expectedRef:$sourcePath")

    @Test
    fun pinnedSourceIgnoresUncommittedEdits() {
        val root = temporaryFolder.newFolder("dirty checkout")
        fixtureGit(root, "init", "--initial-branch=main")
        val source = root.resolve("source.txt")
        val committed = "canonical bytes\n".encodeToByteArray()
        source.writeBytes(committed)
        fixtureGit(root, "add", "source.txt")
        fixtureGit(root, "commit", "-m", "expected revision")
        val expected = fixtureGit(root, "rev-parse", "HEAD")
        source.writeText("uncommitted drift")

        assertExpectedCheckout(root, expected, maySkipWhenAbsent = true)
        assertContentEquals(committed, readPinnedSource(root, "source.txt", expected))
    }

    /** Every discovered vendored resource, compared with the blob at the pinned ref. */
    @Test
    fun copiedVectorsAndCddlMatchTheParallaxCheckoutWhenAvailable() {
        val mappings = discoverVendoredResourceMappings(configuredRepoRoot())
        val checkout = parallaxCheckout(System.getenv(PARALLAX_REPO_ENV), configuredRepoRoot())
            ?: throw AssumptionViolatedException(
                "$REPO_ROOT_PROPERTY is not set, so the sibling Parallax checkout cannot be " +
                    "located and this comparison does not know where to look. This is not the " +
                    "same as there being no checkout: set $PARALLAX_REPO_ENV, or run through " +
                    "Gradle, which supplies the property from the project directory.",
            )
        val root = checkout.root
        assertExpectedCheckout(root, EXPECTED_PARALLAX_REF, checkout.maySkipWhenAbsent)

        for (mapping in mappings) {
            assertResourceMatchesSource(
                resourcePath = mapping.resourcePath,
                root = root,
                sourcePath = mapping.sourcePath,
            )
        }
        assertSourceChecksum(
            root = root,
            sourcePath = "protocol/reference/js/src/wire-identifiers.ts",
            expectedSha256 = "0x4a439506c0d88c771182cdc84b13ba2fdcc8bae858fa594f491a805b6e76992b",
        )
    }

    /**
     * The comparison at the heart of this check must be able to FAIL when the
     * vendored copy differs, and until beid#403 nothing showed that it could.
     *
     * The four checks that existed all inspected the state of the CHECKOUT --
     * a wrong ref, a missing directory, a non-git directory, a detached HEAD.
     * Not one of them varied the VENDORED FILE, so the assertion this whole
     * cross-repo check exists to make had never been observed failing. A
     * verification that cannot express the error it looks for cannot detect
     * it, and a re-vendor blessed by such a check is not a verified re-vendor.
     *
     * These two run against a throwaway git fixture rather than the real
     * parallax checkout, so they hold on every machine including CI, where the
     * real comparison skips entirely for want of a checkout.
     */
    @Test
    fun aVendoredCopyThatDiffersFromTheCheckoutIsDetected() {
        val root = temporaryFolder.newFolder("upstream that drifted")
        val ref = commitFixtureSource(
            root,
            sourcePath = "protocol/cddl/event-definition-v1.cddl",
            content = readVectorResource(VENDORED_RESOURCE_SENTINEL) + "\n; upstream moved on\n",
        )

        val failure = assertFailsWith<AssertionError> {
            assertResourceMatchesSource(
                root = root,
                resourcePath = VENDORED_RESOURCE_SENTINEL,
                sourcePath = "protocol/cddl/event-definition-v1.cddl",
                ref = ref,
            )
        }
        assertTrue(
            failure.message.orEmpty().contains("copied resource drifted"),
            "the failure must name the drift rather than something incidental: ${failure.message}",
        )
    }

    /**
     * The positive control, and it is the half that makes the negative mean
     * something. Without it, a comparison that threw unconditionally would
     * satisfy the test above and still be useless.
     */
    @Test
    fun aVendoredCopyThatMatchesTheCheckoutIsAccepted() {
        val root = temporaryFolder.newFolder("upstream in step")
        val ref = commitFixtureSource(
            root,
            sourcePath = "protocol/cddl/event-definition-v1.cddl",
            content = readVectorResource(VENDORED_RESOURCE_SENTINEL),
        )

        assertResourceMatchesSource(
            root = root,
            resourcePath = VENDORED_RESOURCE_SENTINEL,
            sourcePath = "protocol/cddl/event-definition-v1.cddl",
            ref = ref,
        )
    }

    /**
     * The same question asked of the checksum half: a pinned constant that no
     * longer matches the checkout must fail. The constants are beid's own
     * record of what beid last copied, so nothing outside this repository
     * would notice them going stale.
     */
    @Test
    fun aPinnedChecksumThatNoLongerMatchesTheCheckoutIsDetected() {
        val root = temporaryFolder.newFolder("upstream with a new identifier")
        val ref = commitFixtureSource(
            root,
            sourcePath = "protocol/reference/js/src/wire-identifiers.ts",
            content = "export const WIRE = 1\n",
        )

        assertFailsWith<AssertionError> {
            assertSourceChecksum(
                root = root,
                sourcePath = "protocol/reference/js/src/wire-identifiers.ts",
                expectedSha256 = "0x" + "00".repeat(32),
                ref = ref,
            )
        }
    }

    /**
     * The link that makes [missingCheckoutRemainsSkippable] mean what its name
     * says: only an UNCONFIGURED lookup is allowed to skip.
     *
     * Without this, that test pins a flag rather than a policy -- it would pass
     * unchanged if every lookup, configured or not, were handed
     * `maySkipWhenAbsent = true`, which is precisely the state this fix removes.
     */
    @Test
    fun onlyAnUnconfiguredCheckoutMaySkip() {
        val repoRoot = File("/somewhere/beid")

        val unset = assertNotNull(parallaxCheckout(configured = null, repoRoot = repoRoot))
        assertTrue(unset.maySkipWhenAbsent, "an unset variable falls back and may skip")
        assertEquals(
            File("/somewhere/$DEFAULT_PARALLAX_DIRECTORY_NAME"),
            unset.root,
            "the fallback is the sibling of the repo root, not a path under anyone's home",
        )

        val configured = assertNotNull(
            parallaxCheckout(configured = "/some/operator/choice", repoRoot = repoRoot),
        )
        assertTrue(!configured.maySkipWhenAbsent, "a configured path may never skip")
        assertEquals(File("/some/operator/choice"), configured.root)
    }

    /**
     * The third state, kept distinct from the other two on purpose.
     *
     * Without the repo root there is nowhere to look, which is CANNOT TELL rather
     * than NO CHECKOUT. Folding it into the latter is the same defect this class
     * was changed to remove: a guard reporting an absence it never actually
     * established. A configured path still wins, because then the operator has
     * said where to look and the repo root is irrelevant.
     */
    @Test
    fun anUnknownRepoRootIsNotTreatedAsAnAbsentCheckout() {
        assertNull(
            parallaxCheckout(configured = null, repoRoot = null),
            "with nothing configured and no repo root, there is no checkout to speak of",
        )
        assertNotNull(
            parallaxCheckout(configured = "/some/operator/choice", repoRoot = null),
            "a configured path does not need the repo root",
        )
    }

    /**
     * The fail-open this fix exists for: a configured path that is not there.
     *
     * Before beid#403 this skipped, indistinguishably from CI having no
     * checkout at all, which is how the team convention of pointing
     * PARALLAX_REPO at a nonexistent path silenced the comparison.
     */
    @Test
    fun aConfiguredPathThatDoesNotExistFailsInsteadOfSkipping() {
        val root = File(temporaryFolder.root, "a checkout that was never cloned")

        val failure = assertFailsWith<AssertionError> {
            assertExpectedCheckout(root, EXPECTED_PARALLAX_REF, maySkipWhenAbsent = false)
        }
        val message = failure.message.orEmpty()
        for (detail in listOf(root.absolutePath, PARALLAX_REPO_ENV, EXPECTED_PARALLAX_REF)) {
            assertTrue(message.contains(detail), "Missing '$detail' in: $message")
        }
    }

    /**
     * A real checkout parked on other work, which is the case a developer
     * actually hits and the one measured on this host during beid#403. It fails
     * on the configured path too, not only on the permissive one that
     * [wrongCheckoutRefFailsBeforeComparingFiles] covers.
     */
    @Test
    fun aConfiguredCheckoutAtTheWrongCommitFailsLoudly() {
        val root = temporaryFolder.newFolder("parked on another branch")
        fixtureGit(root, "init", "--initial-branch=docs/something-else")
        fixtureGit(root, "commit", "--allow-empty", "-m", "expected revision")
        val expected = fixtureGit(root, "rev-parse", "HEAD")
        fixtureGit(root, "commit", "--allow-empty", "-m", "work that moved on")
        val current = fixtureGit(root, "rev-parse", "HEAD")

        val failure = assertFailsWith<AssertionError> {
            assertExpectedCheckout(root, expected, maySkipWhenAbsent = false)
        }
        val message = failure.message.orEmpty()
        for (detail in listOf(root.absolutePath, "docs/something-else", current, expected)) {
            assertTrue(message.contains(detail), "Missing '$detail' in: $message")
        }
    }

    /** Commits one file into a throwaway repository and returns its commit id. */
    private fun commitFixtureSource(root: File, sourcePath: String, content: String): String {
        fixtureGit(root, "init", "--initial-branch=main")
        val file = File(root, sourcePath)
        file.parentFile.mkdirs()
        file.writeText(content)
        fixtureGit(root, "add", sourcePath)
        fixtureGit(root, "commit", "-m", "vendored fixture")
        return fixtureGit(root, "rev-parse", "HEAD")
    }

    private fun assertResourceMatchesSource(
        root: File,
        resourcePath: String,
        sourcePath: String,
        ref: String = EXPECTED_PARALLAX_REF,
    ) {
        val copied = readVectorResource(resourcePath).encodeToByteArray()
        val canonical = readPinnedSource(root, sourcePath, ref)
        assertEquals(
            Sha256.digest(canonical).toPrefixedHex(),
            Sha256.digest(copied).toPrefixedHex(),
            "copied resource drifted from ${root.absolutePath} at $ref:$sourcePath",
        )
    }

    private fun assertSourceChecksum(
        root: File,
        sourcePath: String,
        expectedSha256: String,
        ref: String = EXPECTED_PARALLAX_REF,
    ) {
        val canonical = readPinnedSource(root, sourcePath, ref)
        assertEquals(expectedSha256, Sha256.digest(canonical).toPrefixedHex(),
            "${root.absolutePath} at $ref:$sourcePath")
    }
}
