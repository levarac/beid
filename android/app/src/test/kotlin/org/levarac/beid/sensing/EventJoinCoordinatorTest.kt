package org.levarac.beid.sensing

import kotlin.test.Test
import kotlin.test.assertEquals
import org.levarac.barnard.BarnardPermissionError
import org.levarac.barnard.BarnardPermissionResult
import org.levarac.barnard.BarnardPermissionStatus

private fun fakeStatus(canScan: Boolean, canAdvertise: Boolean): BarnardPermissionStatus =
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

class EventJoinCoordinatorTest {
    @Test
    fun grantedWithoutScanCapabilityMapsToPermissionDenied() {
        val result = BarnardPermissionResult.Granted(fakeStatus(canScan = false, canAdvertise = true))

        assertEquals(EventJoinUiState.PermissionDenied, mapPermissionResultToState(result))
    }

    @Test
    fun grantedWithoutAdvertiseCapabilityMapsToPermissionDenied() {
        val result = BarnardPermissionResult.Granted(fakeStatus(canScan = true, canAdvertise = false))

        assertEquals(EventJoinUiState.PermissionDenied, mapPermissionResultToState(result))
    }

    @Test
    fun failedWithNoActivityErrorMapsToJoinFailedNotPermissionDenied() {
        val status = fakeStatus(canScan = true, canAdvertise = true)
        val error = BarnardPermissionError(code = "E_NO_ACTIVITY", message = "no activity attached", status = status)

        assertEquals(EventJoinUiState.JoinFailed, mapPermissionResultToState(BarnardPermissionResult.Failed(error)))
    }

    @Test
    fun failedWithPermissionRequestInProgressErrorMapsToJoinFailedNotPermissionDenied() {
        val status = fakeStatus(canScan = true, canAdvertise = true)
        val error = BarnardPermissionError(
            code = "E_PERMISSION_REQUEST_IN_PROGRESS",
            message = "a request is already in flight",
            status = status,
        )

        assertEquals(EventJoinUiState.JoinFailed, mapPermissionResultToState(BarnardPermissionResult.Failed(error)))
    }
}
