// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import CoreBluetooth
import Foundation

enum BluetoothAuthorizationState: Equatable {
  case notDetermined
  case denied
  case poweredOff
  case granted
}

/// Lightweight, app-level Bluetooth power-state watcher for screen 03
/// (Bluetooth-off state). Deliberately separate from `SensingCoordinator`'s
/// internal `BarnardEngine` managers — this only cares about power state,
/// not scanning/advertising, and multiple `CBCentralManager` instances are
/// supported by CoreBluetooth.
@MainActor
final class BluetoothMonitor: NSObject, ObservableObject {
  @Published private(set) var state: BluetoothAuthorizationState = .notDetermined

  var isPoweredOff: Bool { state == .poweredOff }

  private let makeCentralManager: (CBCentralManagerDelegate) -> CBCentralManager?
  private var manager: CBCentralManager?
  private var permissionWaiters: [CheckedContinuation<BluetoothAuthorizationState, Never>] = []

  /// Tests can suppress native manager construction without replacing state
  /// publication or permission resolution. Normal callers use CoreBluetooth.
  init(
    makeCentralManager: @escaping (CBCentralManagerDelegate) -> CBCentralManager? = {
      CBCentralManager(delegate: $0, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }
  ) {
    self.makeCentralManager = makeCentralManager
    super.init()
  }

  func start() {
    guard manager == nil else { return }
    manager = makeCentralManager(self)
  }

  func waitForAuthorizationResolution() async -> BluetoothAuthorizationState {
    if state != .notDetermined {
      return state
    }

    return await withCheckedContinuation { continuation in
      permissionWaiters.append(continuation)
    }
  }

  /// The native delegate calls this after mapping and its MainActor hop.
  /// A deterministic caller exercises that same body, not hardware delivery.
  func receiveAuthorizationState(_ state: BluetoothAuthorizationState) {
    self.state = state
    guard state != .notDetermined else { return }
    let waiters = permissionWaiters
    permissionWaiters.removeAll()
    waiters.forEach { $0.resume(returning: state) }
  }
}

extension BluetoothMonitor: CBCentralManagerDelegate {
  nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
    let state: BluetoothAuthorizationState
    switch CBManager.authorization {
    case .notDetermined:
      state = .notDetermined
    case .denied, .restricted:
      state = .denied
    case .allowedAlways:
      switch central.state {
      case .poweredOff:
        state = .poweredOff
      case .poweredOn:
        state = .granted
      case .unauthorized:
        state = .denied
      default:
        state = .notDetermined
      }
    @unknown default:
      state = .notDetermined
    }

    Task { @MainActor in
      self.receiveAuthorizationState(state)
    }
  }
}
