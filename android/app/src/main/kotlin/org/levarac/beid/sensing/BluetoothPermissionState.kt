package org.levarac.beid.sensing

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import org.levarac.barnard.BarnardPermissionResult

/** The permission state needed to choose the onboarding destination. */
enum class BluetoothPermissionState {
    NotDetermined,
    Denied,
    Granted,
}

/**
 * Converts Barnard's native permission result into the host's onboarding
 * state. A failed request is not a denial: no user answer was observed, so
 * onboarding must not advance.
 */
fun mapOnboardingPermissionResult(result: BarnardPermissionResult): BluetoothPermissionState = when (result) {
    is BarnardPermissionResult.Granted ->
        if (result.status.canScan && result.status.canAdvertise) {
            BluetoothPermissionState.Granted
        } else {
            BluetoothPermissionState.Denied
        }
    is BarnardPermissionResult.Failed -> BluetoothPermissionState.NotDetermined
}

/** Reads the current runtime permission set for a restored onboarding flow. */
fun currentBluetoothPermissionState(context: Context): BluetoothPermissionState {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
        return BluetoothPermissionState.Granted
    }

    val requiredPermissions = listOf(
        Manifest.permission.BLUETOOTH_SCAN,
        Manifest.permission.BLUETOOTH_CONNECT,
        Manifest.permission.BLUETOOTH_ADVERTISE,
    )
    return if (requiredPermissions.all { permission ->
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
    }) {
        BluetoothPermissionState.Granted
    } else {
        BluetoothPermissionState.Denied
    }
}
