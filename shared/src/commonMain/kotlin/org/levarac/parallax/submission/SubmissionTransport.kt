package org.levarac.parallax.submission

internal const val MAX_SUBMISSION_RESPONSE_BYTES: Long = 2L * 1_024L * 1_024L

internal data class SubmissionHttpRequest(
    val method: String,
    val url: String,
    val headers: Map<String, String> = emptyMap(),
    val body: ByteArray? = null,
    val timeoutMillis: Int = 4_000,
) {
    override fun toString(): String =
        "SubmissionHttpRequest(method=$method, url=${url.substringBefore('?')}, timeoutMillis=$timeoutMillis)"
}

internal data class SubmissionHttpResponse(
    val statusCode: Int,
    val body: ByteArray,
    val headers: Map<String, String> = emptyMap(),
)

internal interface SubmissionHttpTransport {
    suspend fun execute(request: SubmissionHttpRequest): SubmissionHttpResponse
}

internal class SubmissionTransportTimeoutException(message: String = "submission request timed out") :
    Exception(message)

internal expect fun createPlatformSubmissionHttpTransport(): SubmissionHttpTransport
