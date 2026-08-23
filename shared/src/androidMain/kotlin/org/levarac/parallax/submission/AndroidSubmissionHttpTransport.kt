package org.levarac.parallax.submission

import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

internal actual fun createPlatformSubmissionHttpTransport(): SubmissionHttpTransport =
    AndroidSubmissionHttpTransport()

private class AndroidSubmissionHttpTransport : SubmissionHttpTransport {
    override suspend fun execute(request: SubmissionHttpRequest): SubmissionHttpResponse =
        withContext(Dispatchers.IO) {
            val connection = URL(request.url).openConnection() as HttpURLConnection
            try {
                connection.requestMethod = request.method
                connection.connectTimeout = request.timeoutMillis
                connection.readTimeout = request.timeoutMillis
                connection.instanceFollowRedirects = false
                request.headers.forEach { (name, value) -> connection.setRequestProperty(name, value) }
                request.body?.let { body ->
                    connection.doOutput = true
                    connection.setFixedLengthStreamingMode(body.size)
                    connection.outputStream.use { output -> output.write(body) }
                }
                val status = connection.responseCode
                val stream = if (status >= 400) connection.errorStream else connection.inputStream
                SubmissionHttpResponse(
                    statusCode = status,
                    body = stream?.use(::readBoundedBytes) ?: ByteArray(0),
                    headers = connection.headerFields
                        .filterKeys { it != null }
                        .mapKeys { it.key!! }
                        .mapValues { (_, values) -> values.joinToString(",") },
                )
            } catch (error: SocketTimeoutException) {
                throw SubmissionTransportTimeoutException(
                    error.message?.takeIf { it.isNotBlank() } ?: "submission request timed out",
                )
            } finally {
                connection.disconnect()
            }
        }
}

private fun readBoundedBytes(stream: InputStream): ByteArray {
    val output = ByteArrayOutputStream()
    val buffer = ByteArray(8 * 1_024)
    var total = 0L
    while (true) {
        val count = stream.read(buffer)
        if (count < 0) break
        total += count
        require(total <= MAX_SUBMISSION_RESPONSE_BYTES) {
            "submission HTTP response exceeds the configured limit"
        }
        output.write(buffer, 0, count)
    }
    return output.toByteArray()
}
