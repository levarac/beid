package org.levarac.beid.support

import android.content.Intent
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.levarac.beid.sensing.EventJoinUiState
import org.levarac.beid.sensing.ScanEventSession
import org.levarac.beid.sensing.ScanPhase
import org.levarac.beid.sensing.OwnerKeyStorageFailure
import org.levarac.beid.shared.event.EventJoinFailureReason
import org.levarac.beid.shared.support.SupportBundleRecorder
import org.levarac.beid.BuildConfig
import org.json.JSONObject
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class SupportDiagnosticsTest {
    @Test
    fun sharePayloadUsesSharedOutputWithoutUiEventPayloads() {
        val secret = "synthetic-private-key-DO-NOT-SHARE"
        val rpid = "a1b2c3d4e5f60718293a4b5c6d7e8f90ab"
        val hexHash = "ef93b80721fc4e29d8a37594303a251f6eaebe88b41bb29d17da1e905b5224af"
        val diagnostics = SupportDiagnostics(clock = { 123L })
        diagnostics.accept(EventJoinUiState.Sensing(ScanPhase.EventFound(ScanEventSession(secret))))
        diagnostics.accept(EventJoinUiState.Sensing(ScanPhase.Recording(ScanEventSession(rpid), 5)))
        diagnostics.accept(EventJoinUiState.Sensing(ScanPhase.SignalLost(ScanEventSession(hexHash), 7)))
        for (reason in OwnerKeyStorageFailure.entries) {
            diagnostics.accept(EventJoinUiState.OwnerKeyUnavailable(reason))
        }
        diagnostics.accept(EventJoinUiState.JoinFailed(EventJoinFailureReason.NETWORK_REQUIRED))

        val output = diagnostics.exportJson()
        val chooser = supportShareIntent(output, "Share support information")
        assertEquals(Intent.ACTION_CHOOSER, chooser.action)
        val send = chooser.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)!!
        assertEquals(Intent.ACTION_SEND, send.action)
        assertEquals("text/plain", send.type)
        val bytes = send.getStringExtra(Intent.EXTRA_TEXT)!!.toByteArray(Charsets.UTF_8)
        val actual = bytes.toString(Charsets.UTF_8)
        assertEquals(output, actual)
        assertFalse(actual.contains(secret))
        assertFalse(actual.contains(rpid))
        for (forbidden in listOf(
            "synthetic-private", "a1b2c3d4", "7e8f90ab", "obLD1OX2BxgpOktcbX6PkKs=",
            "f4adc8d6d9e25499cf15290fffecb8eeff25a7027854cd1adbe5138eba494c22",
            hexHash,
        )) assertFalse(actual.contains(forbidden))
        for (reason in OwnerKeyStorageFailure.entries) assertFalse(actual.contains(reason.name))
        assertTrue(actual.contains("RECORDING"))
        assertTrue(actual.contains("SIGNAL_LOST"))
        assertTrue(actual.contains("OWNER_KEY_UNAVAILABLE"))
        assertTrue(actual.contains("NETWORK_REQUIRED"))
        assertEquals(BuildConfig.VERSION_NAME, JSONObject(actual).getString("appVersion"))
        assertEquals(BuildConfig.VERSION_CODE.toString(), JSONObject(actual).getString("build"))
        val json = JSONObject(actual)
        assertTrue(json.has("gitHeight"))
        if (BuildConfig.GIT_HEIGHT == "local") {
            assertTrue(json.isNull("gitHeight"))
        } else {
            assertTrue(json.get("gitHeight") is Number)
            assertEquals(BuildConfig.GIT_HEIGHT.toLong(), json.getLong("gitHeight"))
        }
        assertEquals(SupportBundleRecorder::class.java, diagnostics.recorder.javaClass)
    }
}
