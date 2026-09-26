// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Foundation

/// The UI-facing result of resolving a real event's canonical registry ID.
/// This is deliberately separate from `ScanPhase`: sensing can continue while
/// the registry request is checking, and a registry result never changes the
/// event card's raw event code or the scan reducer's phase.
enum EventIdentityVerification: Equatable, Hashable {
  case notChecked
  case checking
  case verified
  case unavailable
  case notFound
}

/// Lossless native input to the one event-identity status mapper. `context` is
/// opaque here because this slice only needs to know that the KMP resolver
/// returned a non-nil, typed context; no display name or submission material
/// is accepted by this UI path.
struct EventIdentityVerificationResolution {
  let isSuccess: Bool
  let context: AnyObject?
  let errorCode: String?
  let errorMessage: String?

  init(
    isSuccess: Bool,
    context: AnyObject?,
    errorCode: String?,
    errorMessage: String?
  ) {
    self.isSuccess = isSuccess
    self.context = context
    self.errorCode = errorCode
    self.errorMessage = errorMessage
  }
}

/// Maps the complete raw registry resolution once, without interpreting
/// network errors in the coordinator or the SwiftUI layer.
enum EventIdentityVerificationMapper {
  static let cancellationErrorCode = "cancelled"
  static let notFoundErrorCode = "definition_not_found"

  /// `nil` means the request was cancelled and the current UI status must be
  /// left unchanged. A successful flag without a typed context is malformed
  /// and therefore unavailable, never verified.
  static func map(
    _ resolution: EventIdentityVerificationResolution
  ) -> EventIdentityVerification? {
    if resolution.errorCode == cancellationErrorCode {
      return nil
    }
    if resolution.isSuccess, resolution.context != nil {
      return .verified
    }
    if resolution.errorCode == notFoundErrorCode {
      return .notFound
    }
    return .unavailable
  }
}
