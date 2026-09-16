package org.levarac.beid.sensing

import android.os.SystemClock
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.levarac.beid.shared.clock.ClockPreflight
import org.levarac.beid.shared.clock.ClockPreflightState

/**
 * The `eninSeconds` beid's Barnard engine runs at (beid#464).
 *
 * beid never configures the engine's ENIN length, so the engine runs at the
 * SDK default, and Barnard 0.9.2 does not expose the value it holds. It is
 * named here once so the preflight is judged against the deployment value
 * rather than an unexplained literal; change it together with any Barnard
 * ENIN configuration.
 */
internal const val BARNARD_ENGINE_ENIN_SECONDS: Int = 300

/** Supplies one trusted HTTP `Date` header, or `null` when none could be read. */
interface TrustedDateSource {
    suspend fun fetchDateHeader(): String?
}

/**
 * `https://host[:port]/` of an operator URL template, or `null` when the
 * template is blank or not HTTPS. The preflight trusts only a TLS-authenticated
 * origin, so a missing one is an unmeasurable clock, not a fallback.
 */
fun operatorOriginOrNull(template: String): String? = try {
    val uri = URI(template.replace("{", "%7B").replace("}", "%7D"))
    val host = uri.host
    if (uri.scheme != "https" || host.isNullOrEmpty()) {
        null
    } else {
        val port = if (uri.port == -1) "" else ":${uri.port}"
        "https://$host$port/"
    }
} catch (_: Exception) {
    null
}

/** `HEAD` to the operator origin; any HTTP status is fine, only `Date` is read. */
class OperatorDateHeaderSource(private val originUrl: String?) : TrustedDateSource {
    override suspend fun fetchDateHeader(): String? {
        val origin = originUrl ?: return null
        return withContext(Dispatchers.IO) {
            val connection = URL(origin).openConnection() as HttpURLConnection
            try {
                connection.requestMethod = "HEAD"
                connection.connectTimeout = TIMEOUT_MILLIS
                connection.readTimeout = TIMEOUT_MILLIS
                connection.instanceFollowRedirects = false
                connection.useCaches = false
                connection.setRequestProperty("Cache-Control", "no-cache")
                connection.responseCode
                connection.getHeaderField("Date")
            } finally {
                connection.disconnect()
            }
        }
    }

    private companion object {
        const val TIMEOUT_MILLIS = 4_000
    }
}

/**
 * Thin native adapter over the shared [ClockPreflight]: it reads the clocks,
 * performs the request, and hands the readings to shared, which owns the
 * interval, the cache and the verdict.
 *
 * [state] is `null` until the first check finishes (and while a measurement
 * is in flight); after that it is always one of the three shared states, so a
 * failed fetch is reported as UNDETERMINABLE instead of leaving nothing on
 * screen.
 */
class ClockPreflightController(
    private val source: TrustedDateSource,
    private val wallMillis: () -> Long = System::currentTimeMillis,
    // Counts through deep sleep, which shared requires of the monotonic clock.
    private val monotonicMillis: () -> Long = SystemClock::elapsedRealtime,
    private val eninSeconds: Int = BARNARD_ENGINE_ENIN_SECONDS,
) {
    private val preflight = ClockPreflight()
    private val mutex = Mutex()
    private val _state = MutableStateFlow<ClockPreflightState?>(null)
    val state: StateFlow<ClockPreflightState?> = _state.asStateFlow()

    /** Measures when shared says the cache cannot answer (or [force] is set), then publishes the state. */
    suspend fun check(force: Boolean = false) {
        mutex.withLock {
            if (force || preflight.needsMeasurement(monotonicMillis(), eninSeconds)) {
                _state.value = null
                val requestWall = wallMillis()
                val requestMonotonic = monotonicMillis()
                val header = try {
                    source.fetchDateHeader()
                } catch (error: CancellationException) {
                    throw error
                } catch (_: Exception) {
                    null
                }
                preflight.recordMeasurement(requestWall, requestMonotonic, monotonicMillis(), header)
            }
            _state.value = preflight.state(wallMillis(), monotonicMillis(), eninSeconds)
        }
    }
}
