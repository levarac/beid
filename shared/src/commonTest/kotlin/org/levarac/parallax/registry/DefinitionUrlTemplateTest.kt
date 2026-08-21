package org.levarac.parallax.registry

import kotlin.test.Test
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class DefinitionUrlTemplateTest {
    @Test
    fun rejectsUserInfoInHttpsTemplate() {
        assertNull(
            createDefinitionUrlTemplate(
                "https://reader:secret@defs.example/{definitionHash}.cbor",
            ),
        )
    }

    @Test
    fun rejectsNonLoopbackHttpTemplate() {
        assertNull(
            createDefinitionUrlTemplate("http://defs.example/{definitionHash}.cbor"),
        )
    }

    @Test
    fun rejectsLoopbackPrefixHostConfusion() {
        assertNull(
            createDefinitionUrlTemplate(
                "http://127.0.0.1:80@evil.example/{definitionHash}.cbor",
            ),
        )
    }

    @Test
    fun acceptsExplicitLoopbackHttpTemplate() {
        assertNotNull(
            createDefinitionUrlTemplate(
                "http://127.0.0.1:8080/{definitionHash}.cbor",
            ),
        )
    }
}
