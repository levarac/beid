package org.levarac.beid.devicelab

import android.Manifest
import android.os.Build
import android.os.SystemClock
import android.util.Log
import androidx.test.ext.junit.rules.ActivityScenarioRule
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import org.junit.Rule
import org.junit.Test
import org.levarac.barnard.BarnardEvent
import org.levarac.beid.MainActivity
import org.levarac.beid.persistence.BindingRecordStore
import org.levarac.beid.persistence.SelfProofRecordStore
import org.levarac.beid.sensing.BarnardEventJoinEngine
import org.levarac.beid.sensing.BarnardSensingCryptography
import org.levarac.beid.sensing.EventJoinCoordinator

/** Two-device physical-BLE entry point selected by the device-lab runner. */
class TwoDeviceBleDiscoveryTest {
    @get:Rule(order = 0)
    val runtimePermissionRule: GrantPermissionRule = GrantPermissionRule.grant(*runtimePermissions())

    @get:Rule(order = 1)
    val activityRule = ActivityScenarioRule(MainActivity::class.java)

    @Test
    fun discoversPeerOverBle() {
        val arguments = InstrumentationRegistry.getArguments()
        val rawRole = arguments.getString(ARG_ROLE)
        val role = when (rawRole) {
            ROLE_ADVERTISER, ROLE_SCANNER -> rawRole
            else -> {
                emitRunnerSignal("RESULT role=${resultToken(rawRole ?: "missing")} status=FAIL reason=invalid_role")
                fail("Instrumentation argument $ARG_ROLE must be advertiser or scanner, got '$rawRole'")
            }
        }
        var activeHarness: Harness? = null
        try {
            val eventCode = arguments.getString(ARG_EVENT_CODE) ?: DEFAULT_EVENT_CODE
            val holdSeconds = positiveLongArgument(ARG_HOLD_SECONDS, DEFAULT_HOLD_SECONDS)
            val timeoutSeconds = positiveLongArgument(ARG_TIMEOUT_SECONDS, DEFAULT_TIMEOUT_SECONDS)
            val harness = createHarness()
            activeHarness = harness
            when (role) {
                ROLE_ADVERTISER -> runAdvertiser(harness, eventCode, holdSeconds, timeoutSeconds)
                ROLE_SCANNER -> runScanner(harness, eventCode, timeoutSeconds)
            }
        } catch (failure: Throwable) {
            emitRunnerSignal(
                "RESULT role=$role status=FAIL reason=${resultToken(failure.message ?: failure.javaClass.simpleName)}",
            )
            throw failure
        } finally {
            activeHarness?.let { harness ->
                activityRule.scenario.onActivity { harness.coordinator.dispose() }
            }
        }
    }

    private fun runAdvertiser(
        harness: Harness,
        eventCode: String,
        holdSeconds: Long,
        timeoutSeconds: Long,
    ) {
        val startFinished = CountDownLatch(1)
        val advertisingConfirmed = AtomicBoolean(false)
        val startFailure = AtomicReference<String?>()
        val coordinatorOnEvent = harness.engine.onEvent

        harness.engine.onEvent = { event ->
            coordinatorOnEvent?.invoke(event)
            if (event is BarnardEvent.Error && event.error.code == "advertise_failed") {
                startFailure.compareAndSet(null, event.error.message)
                startFinished.countDown()
            }
        }
        harness.engine.onDebugEvent = { event ->
            if (event.name == "advertise_started") {
                advertisingConfirmed.set(true)
                startFinished.countDown()
            }
        }
        harness.engine.joinEvent(eventCode)
        harness.engine.startAuto()

        if (!startFinished.await(timeoutSeconds, TimeUnit.SECONDS) || !advertisingConfirmed.get()) {
            fail(startFailure.get() ?: "Advertiser did not confirm start within $timeoutSeconds seconds")
        }

        emitRunnerSignal("DEVICE_LAB_ROLE=advertiser READY")
        Thread.sleep(TimeUnit.SECONDS.toMillis(holdSeconds))
        emitPassResult(ROLE_ADVERTISER, "holdSeconds=$holdSeconds")
    }

    private fun runScanner(harness: Harness, eventCode: String, timeoutSeconds: Long) {
        val startedAt = SystemClock.elapsedRealtime()
        val advertisementSeen = AtomicBoolean(false)
        val scanFailure = AtomicReference<String?>()
        val scanObserved = CountDownLatch(1)
        val detection = AtomicReference<BarnardEvent.Detection?>()
        val peerObserved = CountDownLatch(1)
        val coordinatorOnEvent = harness.engine.onEvent

        harness.engine.onEvent = { event ->
            coordinatorOnEvent?.invoke(event)
            when (event) {
                is BarnardEvent.Error -> if (event.error.code == "scan_failed") {
                    scanFailure.compareAndSet(null, event.error.message)
                    scanObserved.countDown()
                }
                is BarnardEvent.Detection -> {
                    if (detection.compareAndSet(null, event)) {
                        peerObserved.countDown()
                    }
                }
                else -> Unit
            }
        }
        harness.engine.onDebugEvent = { event ->
            if (event.name == "ble_discovery_result" && advertisementSeen.compareAndSet(false, true)) {
                scanObserved.countDown()
            }
        }
        harness.engine.joinEvent(eventCode)
        harness.engine.startScan()

        if (!scanObserved.await(timeoutSeconds, TimeUnit.SECONDS) || !advertisementSeen.get()) {
            fail(scanFailure.get() ?: "Scanner received no BLE callback within $timeoutSeconds seconds")
        }
        emitRunnerSignal("DEVICE_LAB_ROLE=scanner READY")

        val elapsedBeforeWait = SystemClock.elapsedRealtime() - startedAt
        val remainingMillis = (TimeUnit.SECONDS.toMillis(timeoutSeconds) - elapsedBeforeWait).coerceAtLeast(0L)
        if (!peerObserved.await(remainingMillis, TimeUnit.MILLISECONDS)) {
            val observation = if (advertisementSeen.get()) {
                "an advertisement was seen but no BarnardEvent.Detection was received"
            } else {
                "no advertisement was seen"
            }
            fail("Scanner timed out after $timeoutSeconds seconds; scanningStarted=true; $observation")
        }

        val peer = detection.get()?.detection ?: fail("Detection latch completed without a detection")
        val shortId = peer.detectedDisplayId?.takeIf(String::isNotBlank) ?: peer.rpid
        val elapsedMillis = SystemClock.elapsedRealtime() - startedAt
        emitRunnerSignal("DEVICE_LAB_BLE_PASS peer=${shortId.take(SHORT_ID_LENGTH)} ms=$elapsedMillis")
        emitPassResult(
            ROLE_SCANNER,
            "peer=${resultToken(shortId.take(SHORT_ID_LENGTH))} ms=$elapsedMillis",
        )
    }

    private fun createHarness(): Harness {
        val result = AtomicReference<Harness?>()
        activityRule.scenario.onActivity { activity ->
            val engine = BarnardEventJoinEngine(activity)
            val recordSuffix = UUID.randomUUID().toString()
            val coordinator = EventJoinCoordinator(
                engine = engine,
                nowEpochMillis = System::currentTimeMillis,
                coroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
                sensingCryptography = BarnardSensingCryptography(activity.applicationContext),
                selfProofRecordStore = SelfProofRecordStore(
                    File(activity.cacheDir, "device-lab-self-proofs-$recordSuffix.json"),
                ),
                bindingRecordStore = BindingRecordStore(
                    File(activity.cacheDir, "device-lab-bindings-$recordSuffix.json"),
                ),
            )
            result.set(Harness(coordinator, engine))
        }
        return result.get() ?: fail("MainActivity was unavailable for the device-lab harness")
    }

    private fun positiveLongArgument(name: String, defaultValue: Long): Long {
        val raw = InstrumentationRegistry.getArguments().getString(name) ?: return defaultValue
        return raw.toLongOrNull()?.takeIf { it > 0L }
            ?: fail("Instrumentation argument $name must be a positive integer, got '$raw'")
    }

    private fun fail(message: String): Nothing = throw AssertionError(message)

    private data class Harness(
        val coordinator: EventJoinCoordinator,
        val engine: BarnardEventJoinEngine,
    )

    private companion object {
        const val TAG = "DeviceLab"
        const val ARG_ROLE = "role"
        const val ARG_EVENT_CODE = "eventCode"
        const val ARG_HOLD_SECONDS = "holdSeconds"
        const val ARG_TIMEOUT_SECONDS = "timeoutSeconds"
        const val ROLE_ADVERTISER = "advertiser"
        const val ROLE_SCANNER = "scanner"
        const val DEFAULT_EVENT_CODE = "BEID"
        const val DEFAULT_HOLD_SECONDS = 90L
        const val DEFAULT_TIMEOUT_SECONDS = 60L
        const val SHORT_ID_LENGTH = 8

        fun runtimePermissions(): Array<String> = when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> arrayOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_ADVERTISE,
                Manifest.permission.BLUETOOTH_CONNECT,
            )
            else -> arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

        fun emitRunnerSignal(message: String) {
            Log.i(TAG, message)
            println(message)
        }

        fun emitPassResult(role: String, details: String) {
            emitRunnerSignal("RESULT role=$role status=PASS $details")
        }

        fun resultToken(value: String): String = value
            .trim()
            .replace(Regex("[^A-Za-z0-9._:-]+"), "_")
            .ifEmpty { "unknown" }
    }
}
