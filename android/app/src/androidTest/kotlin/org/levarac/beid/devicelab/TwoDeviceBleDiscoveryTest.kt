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
import org.junit.rules.RuleChain
import org.junit.rules.TestRule
import org.junit.runners.model.Statement
import org.levarac.barnard.BarnardEngine
import org.levarac.barnard.BarnardEvent
import org.levarac.beid.MainActivity
import org.levarac.beid.persistence.BindingRecordStore
import org.levarac.beid.persistence.SelfProofRecordStore
import org.levarac.beid.sensing.BarnardEventJoinEngine
import org.levarac.beid.sensing.BarnardSensingCryptography
import org.levarac.beid.sensing.EventJoinCoordinator

/** Two-device physical-BLE entry point selected by the device-lab runner. */
class TwoDeviceBleDiscoveryTest {
    private val resultRole = AtomicReference("unknown")
    private val pendingPassResult = AtomicReference<String?>()
    private val resultBoundaryRule = TestRule { base, _ ->
        object : Statement() {
            override fun evaluate() {
                try {
                    val rawRole = InstrumentationRegistry.getArguments().getString(ARG_ROLE)
                    resultRole.set(resultToken(rawRole ?: "missing"))
                    base.evaluate()
                    val passResult = pendingPassResult.get()
                        ?: fail("Test completed without recording a PASS result")
                    emitRunnerSignal("RESULT $passResult")
                } catch (failure: Throwable) {
                    emitRunnerSignal(
                        "RESULT role=${resultRole.get()} status=FAIL reason=" +
                            resultToken(failure.message ?: failure.javaClass.simpleName),
                    )
                    throw failure
                }
            }
        }
    }
    private val runtimePermissionRule = GrantPermissionRule.grant(*runtimePermissions())
    private val activityRule = ActivityScenarioRule(MainActivity::class.java)

    @get:Rule
    val ruleChain: RuleChain = RuleChain.outerRule(resultBoundaryRule)
        .around(runtimePermissionRule)
        .around(activityRule)

    @Test
    fun discoversPeerOverBle() {
        val arguments = InstrumentationRegistry.getArguments()
        val rawRole = arguments.getString(ARG_ROLE)
        val role = when (rawRole) {
            ROLE_ADVERTISER, ROLE_SCANNER -> rawRole
            else -> fail("Instrumentation argument $ARG_ROLE must be advertiser or scanner, got '$rawRole'")
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
        val coordinatorOnEvent = harness.radio.onEvent

        harness.radio.onEvent = { event ->
            coordinatorOnEvent?.invoke(event)
            if (event is BarnardEvent.Error && event.error.code == "advertise_failed") {
                startFailure.compareAndSet(null, event.error.message)
                startFinished.countDown()
            }
        }
        harness.radio.onDebugEvent = { event ->
            if (event.name == "advertise_started") {
                advertisingConfirmed.set(true)
                startFinished.countDown()
            }
        }
        harness.radio.joinEvent(eventCode)
        harness.radio.startAuto()

        if (!startFinished.await(timeoutSeconds, TimeUnit.SECONDS) || !advertisingConfirmed.get()) {
            fail(startFailure.get() ?: "Advertiser did not confirm start within $timeoutSeconds seconds")
        }
        emitRunnerSignal("DEVICE_LAB_ROLE=advertiser READY")
        Thread.sleep(TimeUnit.SECONDS.toMillis(holdSeconds))
        recordPassResult(ROLE_ADVERTISER, "holdSeconds=$holdSeconds")
    }

    private fun runScanner(harness: Harness, eventCode: String, timeoutSeconds: Long) {
        val startedAt = SystemClock.elapsedRealtime()
        val advertisementSeen = AtomicBoolean(false)
        val scanFailure = AtomicReference<String?>()
        val scanObserved = CountDownLatch(1)
        val detection = AtomicReference<BarnardEvent.Detection?>()
        val peerObserved = CountDownLatch(1)
        val coordinatorOnEvent = harness.radio.onEvent

        harness.radio.onEvent = { event ->
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
        harness.radio.onDebugEvent = { event ->
            if (event.name == "ble_discovery_result" && advertisementSeen.compareAndSet(false, true)) {
                scanObserved.countDown()
            }
        }
        harness.radio.joinEvent(eventCode)
        harness.radio.startScan()

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
        recordPassResult(
            ROLE_SCANNER,
            "peer=${resultToken(shortId.take(SHORT_ID_LENGTH))} ms=$elapsedMillis",
        )
    }

    private fun createHarness(): Harness {
        val result = AtomicReference<Harness?>()
        activityRule.scenario.onActivity { activity ->
            val engine = BarnardEventJoinEngine(activity)
            val radio = BarnardEngine(activity.applicationContext).apply { setActivity(activity) }
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
            result.set(Harness(coordinator, engine, radio))
        }
        return result.get() ?: fail("MainActivity was unavailable for the device-lab harness")
    }

    private fun positiveLongArgument(name: String, defaultValue: Long): Long {
        val raw = InstrumentationRegistry.getArguments().getString(name) ?: return defaultValue
        return raw.toLongOrNull()?.takeIf { it > 0L }
            ?: fail("Instrumentation argument $name must be a positive integer, got '$raw'")
    }

    private fun fail(message: String): Nothing = throw AssertionError(message)

    private fun recordPassResult(role: String, details: String) {
        if (!pendingPassResult.compareAndSet(null, "role=$role status=PASS $details")) {
            fail("PASS result was recorded more than once")
        }
    }

    /**
     * [radio] is barnard itself, held directly and deliberately (beid#374).
     *
     * This test drives raw BLE between two physical devices to prove the radio
     * works; it is not a test of the join gate and it sits BELOW it. Since
     * beid#374 the app's own adapter exposes no string join and no bare
     * `startAuto` -- joining requires a `RegistryVerifiedJoinContext` issued by
     * `shared/` from a real registry read, which is exactly the guarantee that
     * must not have a back door cut into it for a test's convenience. So this
     * harness talks to the SDK directly rather than reaching through the gated
     * adapter, which is what it always meant to do.
     *
     * [coordinator] is still constructed, unchanged, because the scenario also
     * checks that a real coordinator can be stood up on a device.
     */
    private data class Harness(
        val coordinator: EventJoinCoordinator,
        val engine: BarnardEventJoinEngine,
        val radio: BarnardEngine,
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

        fun resultToken(value: String): String = value
            .trim()
            .replace(Regex("[^A-Za-z0-9._:-]+"), "_")
            .ifEmpty { "unknown" }
    }
}
