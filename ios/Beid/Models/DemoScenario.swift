// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation

/// A deterministic Debug-only walkthrough of the real scan-phase reducer.
///
/// The interpreter in `SensingCoordinator` executes these primitive steps
/// through the same device-count and phase-decision path as the existing
/// DemoEvent sequence. It deliberately never enters the window-report or
/// submission-capture path, so a scenario can demonstrate the scan UI without
/// manufacturing a report for delivery.
struct DemoScenario: Equatable, Identifiable {
  enum Step: Equatable {
    /// Gives the UI one render turn before the next state change.
    case pause
    /// Records one synthetic nearby device through the shared aggregation path.
    case observeOneDemoDevice(displayId: String, rpid: String, enin: Int)
    /// Applies the shared scan-phase reducer to the current demo observation.
    case applyPhaseDecision
    /// Advances only demo ENIN bookkeeping; it never opens or closes a report window.
    case advanceDemoWindow
    /// Parks the interpreter in the real Signal Lost phase until the user resumes it.
    case simulateSignalLost
  }

  let identifier: String
  let event: EventSession
  let steps: [Step]

  var id: String { identifier }

  /// The App Review walkthrough keeps the legacy DemoEvent primitive order
  /// byte-for-byte visible as data, including its four self-proof windows.
  static var appReviewGolden: DemoScenario {
    DemoScenario(
      identifier: "appReviewGolden",
      event: appReviewEvent,
      steps: appReviewGoldenSteps()
    )
  }

  /// A dense, steady recording state for reviewing a high-attendance card.
  static let crowdSurge = DemoScenario(
    identifier: "crowdSurge",
    event: crowdSurgeEvent,
    steps: crowdSurgeSteps()
  )

  /// Reaches recording, parks in Signal Lost, then resumes at the next
  /// primitive rather than replaying any prior ceremony or observation.
  static var signalLostMidway: DemoScenario {
    DemoScenario(
      identifier: "signalLostMidway",
      event: signalLostEvent,
      steps: signalLostSteps()
    )
  }

  /// Exercises wrapping and hierarchy with user-visible fixture values that
  /// remain localized like any other App Review demo copy.
  static var longDisplayNames: DemoScenario {
    DemoScenario(
      identifier: "longDisplayNames",
      event: longDisplayNamesEvent,
      steps: appReviewGoldenSteps()
    )
  }

  static var allScenarios: [DemoScenario] {
    [appReviewGolden, crowdSurge, signalLostMidway, longDisplayNames]
  }

  static func named(_ identifier: String) -> DemoScenario? {
    allScenarios.first { $0.identifier == identifier }
  }

  /// Keeps the existing `runDemoSequence(demoEvent:)` seam compatible while
  /// routing it through the same primitive interpreter as named scenarios.
  func replacingEvent(_ event: EventSession) -> DemoScenario {
    DemoScenario(identifier: identifier, event: event, steps: steps)
  }

  private static let appReviewEvent = EventSession.demoSample
  private static let crowdSurgeEvent = EventSession.demoSample
  private static let signalLostEvent = EventSession.demoSample
  private static let longDisplayNamesEvent = EventSession(
    id: "BEID-DEMO-LONG-DISPLAY-NAMES",
    name: String(
      localized: "demo.scenario.longDisplayNames.eventName",
      defaultValue: "The International Gathering for Open, Verifiable and Durable Local Participation",
      comment: "Long fictional event name used only in the Debug demo scenario to verify wrapping and hierarchy."
    ),
    venue: String(
      localized: "demo.scenario.longDisplayNames.venue",
      defaultValue: "The East Exhibition Hall at the Tokyo International Convention and Community Center",
      comment: "Long fictional venue name used only in the Debug demo scenario to verify wrapping and hierarchy."
    )
  )

  private static func appReviewGoldenSteps() -> [Step] {
    let threshold = BeidConfig.eventConfirmThreshold
    var steps: [Step] = [
      .pause,
      .observeOneDemoDevice(displayId: "demo-device-1", rpid: "demo-device-1", enin: 0),
      .applyPhaseDecision,
      .advanceDemoWindow,
      .pause,
    ]
    if threshold > 1 {
      for device in 2...threshold {
        steps.append(
          .observeOneDemoDevice(
            displayId: "demo-device-\(device)",
            rpid: "demo-device-\(device)",
            enin: 1
          )
        )
        steps.append(.applyPhaseDecision)
      }
    }
    steps.append(.advanceDemoWindow)
    for offset in 0..<2 {
      let device = max(1, threshold) + 1 + offset
      steps.append(.pause)
      steps.append(
        .observeOneDemoDevice(
          displayId: "demo-device-\(device)",
          rpid: "demo-device-\(device)",
          enin: offset + 2
        )
      )
      steps.append(.applyPhaseDecision)
      steps.append(.advanceDemoWindow)
    }
    return steps
  }

  private static func crowdSurgeSteps() -> [Step] {
    var steps: [Step] = [.pause]
    for device in 1...40 {
      let enin = (device - 1) / 10
      steps.append(
        .observeOneDemoDevice(
          displayId: "crowd-device-\(device)",
          rpid: "crowd-device-\(device)",
          enin: enin
        )
      )
      steps.append(.applyPhaseDecision)
      if device.isMultiple(of: 10) {
        steps.append(.advanceDemoWindow)
      }
    }
    return steps
  }

  private static func signalLostSteps() -> [Step] {
    let threshold = max(1, BeidConfig.eventConfirmThreshold)
    var steps: [Step] = [
      .pause,
      .observeOneDemoDevice(displayId: "signal-device-1", rpid: "signal-device-1", enin: 0),
      .applyPhaseDecision,
      .advanceDemoWindow,
    ]
    if threshold > 1 {
      steps.append(.pause)
      for device in 2...threshold {
        steps.append(
          .observeOneDemoDevice(
            displayId: "signal-device-\(device)",
            rpid: "signal-device-\(device)",
            enin: 1
          )
        )
        steps.append(.applyPhaseDecision)
      }
    }
    steps.append(.advanceDemoWindow)
    steps.append(.simulateSignalLost)
    steps.append(.pause)
    steps.append(
      .observeOneDemoDevice(
        displayId: "signal-device-\(threshold + 1)",
        rpid: "signal-device-\(threshold + 1)",
        enin: 2
      )
    )
    steps.append(.applyPhaseDecision)
    steps.append(.advanceDemoWindow)
    return steps
  }
}
