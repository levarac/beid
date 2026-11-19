package org.levarac.beid.sensing

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class BluetoothRoutingTest {
    @Test
    fun availabilityCombinesPermissionAndRadio() {
        assertEquals(BluetoothAvailability.Ready, bluetoothAvailabilityOf(BluetoothPermissionState.Granted, radioOn = true))
        assertEquals(BluetoothAvailability.PoweredOff, bluetoothAvailabilityOf(BluetoothPermissionState.Granted, radioOn = false))
        // iOS maps authorization first: a denied app is denied whatever the radio does.
        assertEquals(BluetoothAvailability.Denied, bluetoothAvailabilityOf(BluetoothPermissionState.Denied, radioOn = true))
        assertEquals(BluetoothAvailability.Denied, bluetoothAvailabilityOf(BluetoothPermissionState.Denied, radioOn = false))
        assertEquals(
            BluetoothAvailability.NotDetermined,
            bluetoothAvailabilityOf(BluetoothPermissionState.NotDetermined, radioOn = true),
        )
    }

    /** #832: a later state update recovers the denied screen. */
    @Test
    fun deniedScreenRecoversOnGrantedOrPoweredOff() {
        assertEquals(
            BluetoothRouteTarget.Home,
            bluetoothRouteFor(BluetoothRouteScreen.BluetoothDenied, BluetoothAvailability.Ready),
        )
        assertEquals(
            BluetoothRouteTarget.BluetoothOff,
            bluetoothRouteFor(BluetoothRouteScreen.BluetoothDenied, BluetoothAvailability.PoweredOff),
        )
        assertNull(bluetoothRouteFor(BluetoothRouteScreen.BluetoothDenied, BluetoothAvailability.Denied))
        assertNull(bluetoothRouteFor(BluetoothRouteScreen.BluetoothDenied, BluetoothAvailability.NotDetermined))
    }

    /**
     * A revoked permission sends every post-onboarding screen to the denied
     * guidance. iOS reaches the same screen because the OS terminates the app
     * on a privacy change and `restoreAfterOnboarding` lands on
     * `.bluetoothDenied`; Android also kills the process, but restores the
     * saved back stack instead of re-running onboarding routing.
     */
    @Test
    fun revokedPermissionRoutesPostOnboardingScreensToDenied() {
        assertEquals(
            BluetoothRouteTarget.BluetoothDenied,
            bluetoothRouteFor(BluetoothRouteScreen.App, BluetoothAvailability.Denied),
        )
        assertEquals(
            BluetoothRouteTarget.BluetoothDenied,
            bluetoothRouteFor(BluetoothRouteScreen.BluetoothOff, BluetoothAvailability.Denied),
        )
    }

    /**
     * Other updates retain the current route, as #832's guard does
     * (fix/ios-1.1.1-bluetooth-denied-recovery `AppCoordinator.swift:273-278`): the Bluetooth-off screen recovers only
     * through "I've turned it on", and onboarding is never interrupted.
     */
    @Test
    fun otherUpdatesKeepTheCurrentScreen() {
        assertNull(bluetoothRouteFor(BluetoothRouteScreen.BluetoothOff, BluetoothAvailability.Ready))
        assertNull(bluetoothRouteFor(BluetoothRouteScreen.BluetoothOff, BluetoothAvailability.PoweredOff))
        assertNull(bluetoothRouteFor(BluetoothRouteScreen.App, BluetoothAvailability.Ready))
        assertNull(bluetoothRouteFor(BluetoothRouteScreen.App, BluetoothAvailability.NotDetermined))
        BluetoothAvailability.entries.forEach {
            assertNull(bluetoothRouteFor(BluetoothRouteScreen.Onboarding, it))
        }
    }
}
