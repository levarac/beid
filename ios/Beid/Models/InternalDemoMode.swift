// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#if DEBUG || BEID_INTERNAL_DEMO
import Foundation

/// Internal-build-only event-code namespace for deterministic walkthroughs.
///
/// Keeping the literal codes and their mapping inside this compilation guard
/// makes them absent from Release products rather than merely disabled at
/// runtime.
enum ReservedDemoEventCode {
  enum Classification: Equatable {
    case scenario(DemoScenario)
    case rejected
  }

  private static let prefix = "demo-"

  static func isReserved(_ rawCode: String) -> Bool {
    canonical(rawCode).hasPrefix(prefix)
  }

  static func classify(_ rawCode: String, executionEnabled: Bool) -> Classification {
    let code = canonical(rawCode)
    guard code.hasPrefix(prefix), executionEnabled else { return .rejected }

    let scenarioIdentifier = String(code.dropFirst(prefix.count))
    guard let scenario = DemoScenario.allScenarios.first(where: {
      $0.identifier.lowercased() == scenarioIdentifier
    }) else {
      return .rejected
    }
    return .scenario(scenario)
  }

  private static func canonical(_ rawCode: String) -> String {
    rawCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}

enum DemoBannerPresentation {
  static func isVisible(
    pendingScenarioIdentifier: String?,
    activeScenarioIdentifier: String?
  ) -> Bool {
    pendingScenarioIdentifier != nil || activeScenarioIdentifier != nil
  }
}
#endif
