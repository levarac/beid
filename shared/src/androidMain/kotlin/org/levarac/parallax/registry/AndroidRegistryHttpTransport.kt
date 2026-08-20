package org.levarac.parallax.registry

import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

internal actual fun createPlatformRegistryHttpTransport(): RegistryHttpTransport =
    AndroidRegistryHttpTransport()

private class AndroidRegistryHttpTransport : RegistryHttpTransport {
    override suspend fun execute(request: RegistryHttpRequest): RegistryHttpResponse =
        withContext(Dispatchers.IO) {
            val connection = URL(request.url).openConnection() as HttpURLConnection
            try {
                connection.requestMethod = request.method
                connection.connectTimeout = request.timeoutMillis
                connection.readTimeout = request.timeoutMillis
                connection.instanceFollowRedirects = false
                request.headers.forEach { (name, value) -> connection.setRequestProperty(name, value) }
                request.body?.let { body ->
                    val bytes = body.encodeToByteArray()
                    connection.doOutput = true
                    connection.setFixedLengthStreamingMode(bytes.size)
                    connection.outputStream.use { output -> output.write(bytes) }
                }
                val status = connection.responseCode
                val stream = if (status >= 400) connection.errorStream else connection.inputStream
                val responseBytes = stream?.use(::readBoundedBytes) ?: ByteArray(0)
                RegistryHttpResponse(
                    statusCode = status,
                    body = responseBytes.decodeToString(),
                    bodyBytes = responseBytes,
                )
            } catch (error: SocketTimeoutException) {
                throw RegistryTransportTimeoutException(causeMessage(error))
            } finally {
                connection.disconnect()
            }
        }
}

private fun readBoundedBytes(stream: InputStream): ByteArray {
    val output = ByteArrayOutputStream()
    val buffer = ByteArray(8 * 1_024)
    var total = 0
    while (true) {
        val count = stream.read(buffer)
        if (count < 0) break
        total += count
        require(total <= MAX_HTTP_RESPONSE_BYTES) { "registry HTTP response exceeds the configured limit" }
        output.write(buffer, 0, count)
    }
    return output.toByteArray()
}

private fun causeMessage(error: Throwable): String =
    error.message?.takeIf { it.isNotBlank() } ?: "registry request timed out"

private const val MAX_HTTP_RESPONSE_BYTES: Int = 2 * 1_024 * 1_024
