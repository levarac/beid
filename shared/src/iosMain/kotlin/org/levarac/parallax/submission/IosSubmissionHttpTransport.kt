@file:OptIn(
    kotlinx.cinterop.BetaInteropApi::class,
    kotlinx.cinterop.ExperimentalForeignApi::class,
)

package org.levarac.parallax.submission

import kotlinx.cinterop.addressOf
import kotlinx.cinterop.usePinned
import kotlinx.coroutines.suspendCancellableCoroutine
import platform.Foundation.NSData
import platform.Foundation.NSError
import platform.Foundation.NSHTTPURLResponse
import platform.Foundation.NSLock
import platform.Foundation.NSMutableData
import platform.Foundation.NSMutableURLRequest
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
import platform.Foundation.NSProcessInfo
import platform.Foundation.appendData
import platform.Foundation.dataWithBytes
import platform.Foundation.setHTTPBody
import platform.Foundation.setHTTPMethod
import platform.Foundation.setValue
import platform.darwin.NSObject
import platform.posix.memcpy
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal actual fun createPlatformSubmissionHttpTransport(): SubmissionHttpTransport =
    IosSubmissionHttpTransport()

/** iOS effect observation only; no payloads, receipt bytes, or error descriptions. */
public class IosSubmissionTransportTestEvent internal constructor(
    public val requestId: Long,
    public val phase: String,
    public val method: String,
    public val url: String,
    public val uptimeSeconds: Double,
    public val httpStatus: Int,
    public val errorDomain: String,
    public val errorCode: Long,
)

/** Tests own this subscription. Closing it prevents observation of new requests. */
public class IosSubmissionTransportTestSubscription internal constructor(private val id: Long) {
    public fun close() {
        withTestObserversLock { testObservers.remove(id) }
    }
}

/**
 * Explicit opt-in for Swift integration tests. Android is intentionally untouched:
 * this observes Foundation effects, not a shared submission decision. Production
 * installs no subscriber. Callbacks run outside the lock and cannot change the
 * request, timeout, response, cancellation, or error mapping.
 */
public fun observeIosSubmissionTransportForTesting(
    observer: (IosSubmissionTransportTestEvent) -> Unit,
): IosSubmissionTransportTestSubscription = withTestObserversLock {
    val id = nextTestObserverId++
    testObservers[id] = observer
    IosSubmissionTransportTestSubscription(id)
}

private val testObserversLock = NSLock()
private val testObservers = mutableMapOf<Long, (IosSubmissionTransportTestEvent) -> Unit>()
private var nextTestObserverId = 1L
private var nextTestRequestId = 1L

private inline fun <T> withTestObserversLock(block: () -> T): T {
    testObserversLock.lock()
    return try { block() } finally { testObserversLock.unlock() }
}

private fun observeRequest(method: String, url: String): ObservedSubmissionRequest? = withTestObserversLock {
    if (testObservers.isEmpty()) null else ObservedSubmissionRequest(
        nextTestRequestId++, method, url, testObservers.values.toList(),
    )
}

private class ObservedSubmissionRequest(
    private val id: Long,
    private val method: String,
    private val url: String,
    private val observers: List<(IosSubmissionTransportTestEvent) -> Unit>,
) {
    fun report(phase: String, httpStatus: Int = 0, error: NSError? = null) {
        val event = IosSubmissionTransportTestEvent(
            id, phase, method, url, NSProcessInfo.processInfo.systemUptime,
            httpStatus, error?.domain.orEmpty(), error?.code ?: 0L,
        )
        observers.forEach { observer -> runCatching { observer(event) } }
    }
}

private class IosSubmissionHttpTransport : SubmissionHttpTransport {
    override suspend fun execute(request: SubmissionHttpRequest): SubmissionHttpResponse =
        suspendCancellableCoroutine { continuation ->
            val url = NSURL.URLWithString(request.url)
            if (url == null) {
                continuation.resumeWithException(IllegalArgumentException("invalid submission endpoint URL"))
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
            request.body?.let { body -> nativeRequest.setHTTPBody(body.toNSData()) }

            val observation = observeRequest(request.method, url.absoluteString ?: request.url)
            val delegate = BoundedSubmissionSessionDelegate(
                observation = observation,
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
                observation?.report("attempt")
                task.resume()
            } else {
                observation?.report("cancelled-before-resume")
                session.invalidateAndCancel()
            }
        }
}

private class BoundedSubmissionSessionDelegate(
    private val observation: ObservedSubmissionRequest?,
    private val onSuccess: (SubmissionHttpResponse) -> Unit,
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
        observation?.report("response", httpStatus = response?.statusCode?.toInt() ?: 0)
        if (response == null) {
            completionHandler(NSURLSessionResponseCancel)
            fail(session, Exception("submission HTTP response was not HTTP"))
            return
        }
        if (response.expectedContentLength > MAX_SUBMISSION_RESPONSE_BYTES) {
            completionHandler(NSURLSessionResponseCancel)
            fail(session, IllegalArgumentException("submission HTTP response exceeds the configured limit"))
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
        if (chunkBytes > MAX_SUBMISSION_RESPONSE_BYTES - receivedBytes) {
            dataTask.cancel()
            fail(session, IllegalArgumentException("submission HTTP response exceeds the configured limit"))
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
        observation?.report(
            "completed", httpStatus = httpResponse?.statusCode?.toInt() ?: 0, error = didCompleteWithError,
        )
        if (completed) {
            session.finishTasksAndInvalidate()
            return
        }
        if (didCompleteWithError != null) {
            fail(session, didCompleteWithError.toSubmissionTransportException())
            return
        }
        val response = httpResponse
        if (response == null) {
            fail(session, Exception("submission HTTP response was not HTTP"))
            return
        }
        completed = true
        session.finishTasksAndInvalidate()
        onSuccess(
            SubmissionHttpResponse(
                statusCode = response.statusCode.toInt(),
                body = receivedData.toByteArray(),
                headers = response.allHeaderFields.entries.associate { (name, value) ->
                    name.toString() to value.toString()
                },
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

private fun ByteArray.toNSData(): NSData = usePinned { pinned ->
    if (isEmpty()) {
        NSData.dataWithBytes(null, 0u)
    } else {
        NSData.dataWithBytes(pinned.addressOf(0), size.toULong())
    }
}

private fun NSData.toByteArray(): ByteArray {
    val output = ByteArray(length.toInt())
    if (output.isNotEmpty()) {
        output.usePinned { pinned -> memcpy(pinned.addressOf(0), bytes, length) }
    }
    return output
}

private fun NSError.toSubmissionTransportException(): Throwable =
    if (code == NS_URL_ERROR_TIMED_OUT) {
        SubmissionTransportTimeoutException("submission request timed out")
    } else {
        Exception("submission HTTP transport failed")
    }

private const val NS_URL_ERROR_TIMED_OUT: Long = -1_001
