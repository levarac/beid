// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation

/// Wallet connect+binding lifecycle for the currently recording event.
/// Separate from `ScanPhase` because its trigger (next foreground) is
/// decoupled from phase transitions — see
/// `docs/specs/scan-slice2-redesign.md` §5.6.
///
/// Sub-slice 2a wired this to `.pendingConnect` the instant `.recording`
/// begins (state only). Sub-slice 2b drives the rest:
/// `.connecting`/`.awaitingApproval`/`.bound`/`.failed`, via the connect+
/// binding interstitial (`EventBindingSheetView`) and
/// `SensingCoordinator`'s binding methods. See `BindingRecord`
/// (`Persistence/BindingRecord.swift`) for what `.bound` carries.
enum EventBindingState: Equatable {
  case none
  case pendingConnect(EventSession)
  case connecting
  case awaitingApproval
  case bound(BindingRecord)
  case failed(reason: String)
}

extension EventBindingState {
  /// Keeps the pending binding copy aligned with the live scan phase without
  /// changing an already-started binding attempt.
  func updatingIdentityVerification(
    forEventID eventID: String,
    to identityVerification: EventIdentityVerification
  ) -> EventBindingState {
    guard case .pendingConnect(let event) = self, event.id == eventID else {
      return self
    }
    return .pendingConnect(event.replacingIdentityVerification(identityVerification))
  }
}
