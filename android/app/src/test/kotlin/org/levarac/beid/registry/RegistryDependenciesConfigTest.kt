package org.levarac.beid.registry

import org.levarac.beid.BuildConfig
import org.levarac.parallax.registry.createDefinitionUrlTemplate
import org.levarac.parallax.registry.createEventCodeHashLookupUrlTemplate
import org.levarac.parallax.registry.createEventKeySetUrlTemplate
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * beid#584: the Android build shipped with `EVENT_DEFINITION_URL_TEMPLATE`
 * and `EVENT_KEY_SET_URL_TEMPLATE` defaulting to the empty string while
 * `ios/project.yml` baked both in, and nothing in the repository, CI or the
 * documented build commands supplied them. `createSepoliaRegistryClient`
 * treats a blank template as "not configured", so every
 * `resolveEventDefinition` on Android threw `NOT_CONFIGURED`, the shared
 * reducer recorded `LOOKUP_UNAVAILABLE`, and a discovered event could never
 * leave "Waiting for event verification" — on the same beacon that iOS
 * verified.
 *
 * The assertions compare against literals rather than against the Gradle
 * defaults they came from, for the reason `BeidConfigTest` records: a test
 * that read the same source the production value reads would stay green
 * under any mutation of it, including a revert to the empty string.
 *
 * The cost of that choice is deliberate and worth stating, because it will
 * surprise someone: a build carrying `-Pbeid.definitionUrlTemplate=...` or
 * `-Pbeid.eventKeySetUrlTemplate=...` turns these red. Pointing a lab build
 * at another operator is a legitimate thing to do, and this test says it is
 * not the shipped configuration rather than that it is wrong. Reading the
 * expected value back from the same Gradle property would remove the noise
 * and the protection together (PR 595 review, P2b).
 */
class RegistryDependenciesConfigTest {

    @Test
    fun eventDefinitionUrlTemplateIsConfiguredAndParses() {
        assertEquals(
            "https://parallax-observation-operator.levarac.workers.dev/artifacts/definitions/{definitionHash}",
            BuildConfig.EVENT_DEFINITION_URL_TEMPLATE,
            "not the shipped definition URL; expected if this build passed -Pbeid.definitionUrlTemplate",
        )
        assertNotNull(createDefinitionUrlTemplate(BuildConfig.EVENT_DEFINITION_URL_TEMPLATE))
    }

    @Test
    fun eventKeySetUrlTemplateIsConfiguredAndParses() {
        assertEquals(
            "https://parallax-observation-operator.levarac.workers.dev/artifacts/key-sets/{keySetDigest}",
            BuildConfig.EVENT_KEY_SET_URL_TEMPLATE,
            "not the shipped key-set URL; expected if this build passed -Pbeid.eventKeySetUrlTemplate",
        )
        assertNotNull(createEventKeySetUrlTemplate(BuildConfig.EVENT_KEY_SET_URL_TEMPLATE))
    }

    /**
     * Already defaulted before beid#584 and asserted here so the three
     * templates the nearby-event path needs are covered by one test: a
     * lookup that resolves against a definition URL that does not exist is
     * the failure this issue was.
     */
    @Test
    fun eventCodeHashLookupUrlTemplateIsConfiguredAndParses() {
        assertTrue(BuildConfig.EVENT_CODE_HASH_LOOKUP_URL_TEMPLATE.isNotBlank())
        assertNotNull(
            createEventCodeHashLookupUrlTemplate(BuildConfig.EVENT_CODE_HASH_LOOKUP_URL_TEMPLATE),
        )
    }
}
