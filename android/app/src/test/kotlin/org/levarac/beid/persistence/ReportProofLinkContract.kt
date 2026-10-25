package org.levarac.beid.persistence

import java.io.File
import java.lang.reflect.InvocationTargetException
import java.util.UUID
import kotlin.test.assertNotNull

/** Reflection lets the contract fail as an assertion before the store exists. */
internal class ReportProofLinkContract(file: File, writer: ((File, ByteArray) -> Unit)? = null) {
    private val type = assertNotNull(
        runCatching { Class.forName("org.levarac.beid.persistence.ReportProofLinkStore") }.getOrNull(),
        "Android must provide the display-only ReportProofLinkStore",
    )
    val instance: Any = if (writer == null) type.getDeclaredConstructor(File::class.java).newInstance(file)
        else type.getDeclaredConstructor(File::class.java, Function2::class.java).newInstance(file, writer)

    fun add(windowId: UUID, proofId: UUID) { call("add", windowId, proofId) }
    fun links(): List<Pair<UUID, UUID>> = (call("links") as List<*>).map { row ->
        requireNotNull(row)
        row.javaClass.getMethod("getWindowId").invoke(row) as UUID to
            row.javaClass.getMethod("getProofId").invoke(row) as UUID
    }
    fun proofIdFor(windowId: UUID): UUID? = call("proofIdFor", windowId) as UUID?
    @Suppress("UNCHECKED_CAST")
    fun windowIdsFor(proofId: UUID): Set<UUID> = call("windowIdsFor", proofId) as Set<UUID>

    private fun call(name: String, vararg args: Any): Any? = try {
        type.getMethod(name, *args.map { it.javaClass }.toTypedArray()).invoke(instance, *args)
    } catch (error: InvocationTargetException) {
        throw error.targetException
    }
}
