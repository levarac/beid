// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BeidSharedKit
import Foundation

/// Cancellation boundary owned by the native verification lifecycle. The
/// request is intentionally not exposed to SwiftUI or report submission.
@MainActor
protocol EventIdentityVerificationRequest: AnyObject {
  func cancel()
}

/// Dedicated registry-read seam for the event-identity status axis. It is
/// separate from `EventDefinitionContextProvider`, which is submission-only.
@MainActor
protocol EventIdentityVerificationSource: AnyObject {
  @discardableResult
  func resolve(
    eventIdHex: String,
    completion: @escaping (EventIdentityVerificationResolution) -> Void
  ) -> any EventIdentityVerificationRequest
}

@MainActor
private final class RegistryEventIdentityVerificationRequest:
  EventIdentityVerificationRequest
{
  private var request:
    ExportedKotlinPackages.org.levarac.parallax.registry.RegistryRequest?

  init(
    request: ExportedKotlinPackages.org.levarac.parallax.registry.RegistryRequest
  ) {
    self.request = request
  }

  func cancel() {
    request?.cancel()
    request = nil
  }

  deinit {
    request?.cancel()
  }
}

/// Production adapter for the registry status row. It forwards the canonical
/// hint exactly to the KMP registry client, uses the safe read pin and current
/// read time, and preserves the raw resolver fields for the pure mapper.
@MainActor
final class RegistryEventIdentityVerificationSource: EventIdentityVerificationSource {
  private let client:
    ExportedKotlinPackages.org.levarac.parallax.registry.RegistryClient

  init(
    client: ExportedKotlinPackages.org.levarac.parallax.registry.RegistryClient
  ) {
    self.client = client
  }

  @discardableResult
  func resolve(
    eventIdHex: String,
    completion: @escaping (EventIdentityVerificationResolution) -> Void
  ) -> any EventIdentityVerificationRequest {
    let request = client.resolveEventDefinition(
      eventIdHex: eventIdHex,
      pin: ExportedKotlinPackages.org.levarac.parallax.registry.safeRegistryReadPin(),
      useTimeEpochSeconds: Int64(Date().timeIntervalSince1970)
    ) { resolution in
      let rawResolution = EventIdentityVerificationResolution(
        isSuccess: resolution.isSuccess,
        context: resolution.context.map { $0 as AnyObject },
        errorCode: resolution.errorCode,
        errorMessage: resolution.errorMessage
      )
      Task { @MainActor in
        completion(rawResolution)
      }
    }
    return RegistryEventIdentityVerificationRequest(request: request)
  }
}
