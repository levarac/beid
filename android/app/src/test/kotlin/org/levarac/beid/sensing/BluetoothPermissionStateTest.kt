package org.levarac.beid.sensing

import kotlin.test.Test
import kotlin.test.assertEquals
import org.levarac.barnard.BarnardPermissionError
import org.levarac.barnard.BarnardPermissionResult
import org.levarac.barnard.BarnardPermissionStatus

private fun permissionStatus(canScan: Boolean, canAdvertise: Boolean): BarnardPermissionStatus =
    BarnardPermissionStatus(
        platform = "android",
        permissions = emptyMap(),
        requiredPermissions = emptyList(),
        missingPermissions = emptyList(),
        requestablePermissions = emptyList(),
        blockedPermissions = emptyList(),
        canScan = canScan,
        canAdvertise = canAdvertise,
    )

class BluetoothPermissionStateTest {
    @Test
    fun deniedPermissionMapsToDenied() {
        val result = BarnardPermissionResult.Granted(
            permissionStatus(canScan = false, canAdvertise = false),
        )

        assertEquals(BluetoothPermissionState.Denied, mapOnboardingPermissionResult(result))
    }

    @Test
    fun grantedPermissionMapsToGranted() {
        val result = BarnardPermissionResult.Granted(
            permissionStatus(canScan = true, canAdvertise = true),
        )

        assertEquals(BluetoothPermissionState.Granted, mapOnboardingPermissionResult(result))
    }

    @Test
    fun permissionRequestFailureDoesNotAdvanceFromUndetermined() {
        val result = BarnardPermissionResult.Failed(
            BarnardPermissionError(
                code = "E_PERMISSION_REQUEST_IN_PROGRESS",
                message = "permission request unavailable",
                status = permissionStatus(canScan = false, canAdvertise = false),
            ),
        )

        assertEquals(BluetoothPermissionState.NotDetermined, mapOnboardingPermissionResult(result))
    }
}
