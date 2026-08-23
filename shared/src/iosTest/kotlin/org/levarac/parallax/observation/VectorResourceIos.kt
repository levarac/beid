package org.levarac.parallax.observation

import platform.Foundation.NSBundle
import kotlinx.cinterop.ByteVar
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.readBytes
import kotlinx.cinterop.reinterpret
import platform.Foundation.NSFileManager
import platform.Foundation.NSProcessInfo

@OptIn(ExperimentalForeignApi::class)
internal actual fun readVectorResource(path: String): String {
    val slash = path.lastIndexOf('/')
    val directory = path.takeIf { slash >= 0 }?.substring(0, slash)
    val file = if (slash >= 0) path.substring(slash + 1) else path
    val dot = file.lastIndexOf('.')
    val resourceName = if (dot >= 0) file.substring(0, dot) else file
    val resourceType = if (dot >= 0) file.substring(dot + 1) else null
    val bundleResourcePath = NSBundle.mainBundle.pathForResource(
        name = resourceName,
        ofType = resourceType,
        inDirectory = directory,
    )
    val target = listOf("iosSimulatorArm64", "iosArm64").firstOrNull {
        NSBundle.mainBundle.bundlePath.contains("/$it/")
    }
    val processedResourcePath = target?.let {
        "${NSBundle.mainBundle.bundlePath}/../../../processedResources/$it/test/$path"
    }
    // Kotlin/Native's standalone test executable does not create an NSBundle
    // for commonTest resources. Keep the fixture in its canonical
    // commonTest/resources location and walk from both the simulator's
    // working directory and the test executable path. The latter remains
    // stable even when XCTest changes the process working directory.
    val sourceRoots = listOfNotNull(
        NSFileManager.defaultManager.currentDirectoryPath,
        NSProcessInfo.processInfo.arguments.firstOrNull()?.toString(),
        NSBundle.mainBundle.bundlePath,
    )
    val sourceResourcePaths = sourceRoots.flatMap { root ->
        buildList {
            var directory: String? = root.let { value ->
                if (value.endsWith('/')) value.trimEnd('/') else value.substringBeforeLast('/')
            }
            repeat(16) {
                val base = directory ?: return@repeat
                add("$base/src/commonTest/resources/$path")
                add("$base/shared/src/commonTest/resources/$path")
                val parent = base.substringBeforeLast('/')
                directory = if (parent.isEmpty() || parent == base) null else parent
            }
        }
    }.distinct()
    val data = (listOfNotNull(bundleResourcePath, processedResourcePath) + sourceResourcePaths)
        .asSequence()
        .distinct()
        .mapNotNull { NSFileManager.defaultManager.contentsAtPath(it) }
        .firstOrNull()
        ?: error("unable to read test resource: $path")
    return data.bytes!!.reinterpret<ByteVar>().readBytes(data.length.toInt()).decodeToString()
}
