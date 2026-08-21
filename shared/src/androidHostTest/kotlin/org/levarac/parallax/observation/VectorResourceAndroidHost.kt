package org.levarac.parallax.observation

internal actual fun readVectorResource(path: String): String {
    val stream = Thread.currentThread().contextClassLoader
        ?.getResourceAsStream(path)
        ?: error("missing test resource: $path")
    return stream.use { it.readBytes().decodeToString() }
}
