package org.levarac.parallax.observation

import platform.Foundation.NSBundle
import kotlinx.cinterop.ByteVar
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.readBytes
import kotlinx.cinterop.reinterpret
import platform.Foundation.NSFileManager

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
    val data = listOfNotNull(bundleResourcePath, processedResourcePath)
        .asSequence()
        .mapNotNull { NSFileManager.defaultManager.contentsAtPath(it) }
        .firstOrNull()
        ?: error("unable to read test resource: $path")
    return data.bytes!!.reinterpret<ByteVar>().readBytes(data.length.toInt()).decodeToString()
}
