// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation

/// Wallet connect+binding lifecycle for the currently recording event.
/// Separate from `ScanPhase` because its trigger (next foreground) is
/// decoupled from phase transitions — see
/// `docs/specs/scan-slice2-redesign.md` §5.6.
///
/// Sub-slice 2a wires this to `.pendingConnect` the instant `.recording`
/// begins (state only). The connect+binding interstitial UI that drives
/// `.connecting`/`.awaitingApproval`/`.bound`/`.failed` is sub-slice 2b.
enum EventBindingState: Equatable {
  case none
  case pendingConnect(EventSession)
  case connecting
  case awaitingApproval
  case bound(BindingRecord)
  case failed(reason: String)
}

/// Evidence that a wallet endorsed this device's owner key for one event —
/// the combined wallet `personal_sign` + device countersign round trip
/// (beid#33). Built out fully in sub-slice 2b; only the shape needed for
/// `EventBindingState.bound` to compile exists here.
struct BindingRecord: Equatable {
  let walletAddress: String
  let boundAt: Date
}
