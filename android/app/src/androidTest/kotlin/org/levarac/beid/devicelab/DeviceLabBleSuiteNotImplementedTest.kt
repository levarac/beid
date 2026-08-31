package org.levarac.beid.devicelab

import org.junit.Assert.fail
import org.junit.Test

/** Prevents the absent physical-device BLE scenario from being reported as a pass. */
class DeviceLabBleSuiteNotImplementedTest {
    @Test
    fun twoDeviceBleSuiteMustBeImplemented() {
        fail(
            "The beid two-device BLE instrumentation scenario has not been implemented. " +
                "See docs/device-lab-android-harness.md.",
        )
    }
}
