// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

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
  /// `retryable` is `false` only when retrying cannot succeed (today only
  /// the ERC-6492 smart-wallet result, beid#382); the sheet then offers
  /// Close instead of Try Again. A non-retryable failure is also sticky for
  /// the rest of the session: `SensingCoordinator.declineBinding()` leaves
  /// it in place and `ScanFlowView` only re-presents the sheet from
  /// `.pendingConnect`, so it is not re-offered until the session ends
  /// (beid#591).
  case failed(reason: String, retryable: Bool)
}

/// Outcome of one `completeBinding` call. Never persisted — not a new
/// `EventBindingState` case, not stored on `BindingRecord` (beid#240
/// forbids new unbacked persistent state; beid#359 only makes the
/// *reason returned to the caller* distinguishable). The caller consumes
/// this immediately to pick failure copy, then discards it.
enum BindingCompletionResult: Equatable {
  case bound(BindingRecord)
  /// The wallet signature is ERC-6492-shaped (ends with the 32-byte magic
  /// suffix) — beid does not support smart-contract wallets yet (beid#359).
  /// Retrying can never succeed for this reason; the caller must not imply
  /// otherwise.
  case smartWalletUnsupported
  /// Any other failure: stale/malformed local state, a wallet signature
  /// that isn't 65 bytes (beid#357 — rejected before the owner key ever
  /// runs), or a signature that cryptographically recovers to a different
  /// signer than the claimed address. Deliberately not further split:
  /// unlike the smart-wallet case, none of these are diagnosable from here,
  /// so a retry is genuinely plausible (e.g. transport corruption) and the
  /// existing generic reason stays honest about that uncertainty.
  case notVerified
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
