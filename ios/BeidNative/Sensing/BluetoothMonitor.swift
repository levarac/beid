// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import CoreBluetooth
import Foundation

/// Lightweight, app-level Bluetooth power-state watcher for screen 03
/// (Bluetooth-off state). Deliberately separate from `SensingCoordinator`'s
/// internal `BarnardEngine` managers — this only cares about power state,
/// not scanning/advertising, and multiple `CBCentralManager` instances are
/// supported by CoreBluetooth.
@MainActor
final class BluetoothMonitor: NSObject, ObservableObject {
  @Published private(set) var isPoweredOff = false

  private var manager: CBCentralManager?

  func start() {
    guard manager == nil else { return }
    manager = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
  }
}

extension BluetoothMonitor: CBCentralManagerDelegate {
  nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
    let poweredOff = central.state == .poweredOff
    Task { @MainActor in
      self.isPoweredOff = poweredOff
    }
  }
}
