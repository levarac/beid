// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation
@testable import Beid

/// Fast test double for `VenueDeviceOrganizerViewModel` tests that do not
/// own Barnard/BLE correctness — same role as `DeterministicSensingCryptography`
/// plays for `SensingCryptography`.
final class FakeVenueDeviceBroadcasting: VenueDeviceBroadcasting {
  enum Call: Equatable {
    case startBroadcasting(eventCode: String, label: String)
    case stopBroadcasting
  }

  /// When set, `startBroadcasting` throws this instead of recording a call.
  var startBroadcastingError: Error?
  private(set) var calls: [Call] = []

  func startBroadcasting(eventCode: String, label: String) throws {
    if let startBroadcastingError {
      throw startBroadcastingError
    }
    calls.append(.startBroadcasting(eventCode: eventCode, label: label))
  }

  func stopBroadcasting() {
    calls.append(.stopBroadcasting)
  }
}
