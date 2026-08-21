@file:OptIn(
    kotlinx.cinterop.BetaInteropApi::class,
    kotlinx.cinterop.ExperimentalForeignApi::class,
)

package org.levarac.parallax.registry

import kotlinx.cinterop.addressOf
import kotlinx.cinterop.usePinned
import kotlinx.coroutines.suspendCancellableCoroutine
import platform.Foundation.NSData
import platform.Foundation.NSError
import platform.Foundation.NSHTTPURLResponse
import platform.Foundation.NSMutableData
import platform.Foundation.NSMutableURLRequest
import platform.Foundation.NSString
import platform.Foundation.NSURL
import platform.Foundation.NSURLRequest
import platform.Foundation.NSURLRequestReloadIgnoringLocalCacheData
import platform.Foundation.NSURLResponse
import platform.Foundation.NSURLSession
import platform.Foundation.NSURLSessionConfiguration
import platform.Foundation.NSURLSessionDataDelegateProtocol
import platform.Foundation.NSURLSessionDataTask
import platform.Foundation.NSURLSessionResponseAllow
import platform.Foundation.NSURLSessionResponseCancel
import platform.Foundation.NSURLSessionResponseDisposition
import platform.Foundation.NSURLSessionTask
import platform.Foundation.NSUTF8StringEncoding
import platform.Foundation.appendData
import platform.Foundation.dataUsingEncoding
import platform.Foundation.setHTTPBody
import platform.Foundation.setHTTPMethod
import platform.Foundation.setValue
import platform.darwin.NSObject
import platform.posix.memcpy
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal actual fun createPlatformRegistryHttpTransport(): RegistryHttpTransport =
    IosRegistryHttpTransport()

private class IosRegistryHttpTransport : RegistryHttpTransport {
    override suspend fun execute(request: RegistryHttpRequest): RegistryHttpResponse =
        suspendCancellableCoroutine { continuation ->
            val url = NSURL.URLWithString(request.url)
            if (url == null) {
                continuation.resumeWithException(IllegalArgumentException("invalid registry endpoint URL"))
                return@suspendCancellableCoroutine
            }
            val nativeRequest = NSMutableURLRequest.requestWithURL(
                URL = url,
                cachePolicy = NSURLRequestReloadIgnoringLocalCacheData,
                timeoutInterval = request.timeoutMillis.toDouble() / 1_000.0,
            )
            nativeRequest.setHTTPMethod(request.method)
            request.headers.forEach { (name, value) ->
                nativeRequest.setValue(value, forHTTPHeaderField = name)
            }
            request.body?.let { body ->
                nativeRequest.setHTTPBody((body as NSString).dataUsingEncoding(NSUTF8StringEncoding))
            }

            val delegate = BoundedRegistrySessionDelegate(
                onSuccess = { response ->
                    if (continuation.isActive) continuation.resume(response)
                },
                onFailure = { error ->
                    if (continuation.isActive) continuation.resumeWithException(error)
                },
            )
            val session = NSURLSession.sessionWithConfiguration(
                configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration,
                delegate = delegate,
                delegateQueue = null,
            )
            val task = session.dataTaskWithRequest(nativeRequest)
            continuation.invokeOnCancellation {
                task.cancel()
                session.invalidateAndCancel()
            }
            if (continuation.isActive) {
                task.resume()
            } else {
                session.invalidateAndCancel()
            }
        }
}

private class BoundedRegistrySessionDelegate(
    private val onSuccess: (RegistryHttpResponse) -> Unit,
    private val onFailure: (Throwable) -> Unit,
) : NSObject(), NSURLSessionDataDelegateProtocol {
    private val receivedData = NSMutableData()
    private var receivedBytes = 0L
    private var httpResponse: NSHTTPURLResponse? = null
    private var completed = false

    override fun URLSession(
        session: NSURLSession,
        dataTask: NSURLSessionDataTask,
        didReceiveResponse: NSURLResponse,
        completionHandler: (NSURLSessionResponseDisposition) -> Unit,
    ) {
        val response = didReceiveResponse as? NSHTTPURLResponse
        if (response == null) {
            completionHandler(NSURLSessionResponseCancel)
            fail(session, Exception("registry HTTP response was not HTTP"))
            return
        }
        if (response.expectedContentLength > MAX_HTTP_RESPONSE_BYTES) {
            completionHandler(NSURLSessionResponseCancel)
            fail(session, responseTooLarge())
            return
        }
        httpResponse = response
        completionHandler(NSURLSessionResponseAllow)
    }

    override fun URLSession(
        session: NSURLSession,
        dataTask: NSURLSessionDataTask,
        didReceiveData: NSData,
    ) {
        if (completed) return
        val chunkBytes = didReceiveData.length.toLong()
        if (chunkBytes > MAX_HTTP_RESPONSE_BYTES - receivedBytes) {
            dataTask.cancel()
            fail(session, responseTooLarge())
            return
        }
        receivedData.appendData(didReceiveData)
        receivedBytes += chunkBytes
    }

    override fun URLSession(
        session: NSURLSession,
        task: NSURLSessionTask,
        willPerformHTTPRedirection: NSHTTPURLResponse,
        newRequest: NSURLRequest,
        completionHandler: (NSURLRequest?) -> Unit,
    ) {
        completionHandler(null)
    }

    override fun URLSession(
        session: NSURLSession,
        task: NSURLSessionTask,
        didCompleteWithError: NSError?,
    ) {
        if (completed) {
            session.finishTasksAndInvalidate()
            return
        }
        if (didCompleteWithError != null) {
            fail(session, didCompleteWithError.toRegistryTransportException())
            return
        }
        val response = httpResponse
        if (response == null) {
            fail(session, Exception("registry HTTP response was not HTTP"))
            return
        }
        val bodyBytes = receivedData.toByteArray()
        completed = true
        session.finishTasksAndInvalidate()
        onSuccess(
            RegistryHttpResponse(
                statusCode = response.statusCode.toInt(),
                body = bodyBytes.decodeToString(),
                bodyBytes = bodyBytes,
            ),
        )
    }

    private fun fail(session: NSURLSession, error: Throwable) {
        if (completed) return
        completed = true
        session.invalidateAndCancel()
        onFailure(error)
    }
}

private fun NSData.toByteArray(): ByteArray {
    val output = ByteArray(length.toInt())
    if (output.isNotEmpty()) {
        output.usePinned { pinned ->
            memcpy(pinned.addressOf(0), bytes, length)
        }
    }
    return output
}

private fun NSError.toRegistryTransportException(): Throwable =
    if (code == NS_URL_ERROR_TIMED_OUT) {
        RegistryTransportTimeoutException("registry request timed out")
    } else {
        Exception("registry HTTP transport failed")
    }

private fun responseTooLarge(): IllegalArgumentException =
    IllegalArgumentException("registry HTTP response exceeds the configured limit")

private const val NS_URL_ERROR_TIMED_OUT: Long = -1_001
private const val MAX_HTTP_RESPONSE_BYTES: Long = 2L * 1_024L * 1_024L
