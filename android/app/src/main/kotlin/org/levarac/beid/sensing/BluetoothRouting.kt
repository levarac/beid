package org.levarac.beid.sensing

/**
 * Android's counterpart of iOS's `BluetoothAuthorizationState`
 * (integration/ios-1.1.1 `ios/Beid/Sensing/BluetoothMonitor.swift:7-12`).
 * Authorization is mapped first, so a denied app is [Denied] whatever the
 * radio does (same branch, `BluetoothMonitor.swift:45-71`).
 */
enum class BluetoothAvailability { NotDetermined, Denied, PoweredOff, Ready }

/** Where the app currently is, as far as Bluetooth routing cares. */
enum class BluetoothRouteScreen {
    /** Welcome and the permission explanation: onboarding owns its own routing. */
    Onboarding,
    BluetoothDenied,
    BluetoothOff,

    /** Home and every screen reached from it. */
    App,
}

enum class BluetoothRouteTarget { Home, BluetoothOff, BluetoothDenied }

fun bluetoothAvailabilityOf(permission: BluetoothPermissionState, radioOn: Boolean): BluetoothAvailability =
    when (permission) {
        BluetoothPermissionState.NotDetermined -> BluetoothAvailability.NotDetermined
        BluetoothPermissionState.Denied -> BluetoothAvailability.Denied
        BluetoothPermissionState.Granted ->
            if (radioOn) BluetoothAvailability.Ready else BluetoothAvailability.PoweredOff
    }

/**
 * The route a Bluetooth state update moves the app to, or `null` to stay.
 *
 * - On the denied guidance, a later update recovers it: ready selects Home,
 *   authorized-but-off selects the Bluetooth-off screen. This is #832
 *   (fix/ios-1.1.1-bluetooth-denied-recovery `ios/Beid/Navigation/AppCoordinator.swift:273-278`
 *   feeding `applyBluetoothState`, `:849-866` on that branch).
 * - A revoked permission sends every post-onboarding screen to the denied
 *   guidance. iOS reaches the same screen because the OS terminates the app
 *   on a privacy change and `restoreAfterOnboarding` re-runs
 *   `applyBluetoothState` (integration/ios-1.1.1
 *   `AppCoordinator.swift:431-436,841-858`). Android kills the process too,
 *   but then restores the saved back stack, which skips the
 *   start-destination check.
 * - Everything else keeps the current route, as #832's guard does. The
 *   Bluetooth-off screen returns only through "I've turned it on"
 *   (integration/ios-1.1.1 `ios/Beid/Views/BluetoothOffView.swift:56-58`), and a
 *   radio drop on Home does not leave Home: the same branch shows an inline block
 *   there instead (`ios/Beid/Views/CollectionHomeView.swift:84,186,244-264`; see
 *   [HomeBluetoothStatus]).
 */
fun bluetoothRouteFor(screen: BluetoothRouteScreen, availability: BluetoothAvailability): BluetoothRouteTarget? =
    when (screen) {
        BluetoothRouteScreen.Onboarding -> null
        BluetoothRouteScreen.BluetoothDenied -> when (availability) {
            BluetoothAvailability.Ready -> BluetoothRouteTarget.Home
            BluetoothAvailability.PoweredOff -> BluetoothRouteTarget.BluetoothOff
            BluetoothAvailability.Denied, BluetoothAvailability.NotDetermined -> null
        }
        BluetoothRouteScreen.BluetoothOff, BluetoothRouteScreen.App ->
            if (availability == BluetoothAvailability.Denied) BluetoothRouteTarget.BluetoothDenied else null
    }
