// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

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
    /// Records one synthetic proximity identifier that never resolves to a
    /// display id, through that same aggregation path.
    ///
    /// Deliberately a separate case rather than widening
    /// `observeOneDemoDevice`'s `displayId` to an optional: the App Review
    /// golden sequence is pinned as a step-array literal in both this file
    /// and `DemoScenarioInvariantTests`, and widening the existing payload
    /// would rewrite that literal on both sides in one edit — which is the
    /// shape where a golden quietly stops guarding anything. The coordinator
    /// still routes both cases through one `recordDeviceIdentity` call, so
    /// this adds a vocabulary word, not a second observation path.
    case observeOneUnidentifiedRpid(rpid: String, enin: Int)
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

  /// Stays in Sensing with nothing ever arriving — the "is it even scanning?"
  /// screen, which no other scenario reaches because every other one observes
  /// at least one device.
  static let zeroPeersForever = DemoScenario(
    identifier: "zeroPeersForever",
    event: zeroPeersEvent,
    steps: zeroPeersForeverSteps()
  )

  /// Radio is arriving and none of it identifies: `unidentifiedRpidCount`
  /// climbs while `devicesVerified` stays at 0. This is the pair
  /// `RecordingView`'s diagnostic line (beid#218) exists to tell apart from
  /// "nothing is arriving at all", and it is the only scenario that produces
  /// it.
  ///
  /// Threshold-derived, so it must be a `var`: the step count is a function
  /// of `BeidConfig.eventConfirmThreshold`, which
  /// `eventConfirmThresholdOverrideForTesting` and `-beid-threshold-override`
  /// both move at runtime. A `let` would cache a list built against whichever
  /// threshold happened to be current at first access.
  static var unidentifiedHeavy: DemoScenario {
    DemoScenario(
      identifier: "unidentifiedHeavy",
      event: unidentifiedHeavyEvent,
      steps: unidentifiedHeavySteps()
    )
  }

  static var allScenarios: [DemoScenario] {
    [
      appReviewGolden,
      crowdSurge,
      signalLostMidway,
      longDisplayNames,
      zeroPeersForever,
      unidentifiedHeavy,
    ]
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
  private static let zeroPeersEvent = EventSession.demoSample
  private static let unidentifiedHeavyEvent = EventSession.demoSample
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

  /// Four render turns of nothing. The count is arbitrary but not zero:
  /// `runDemoScenario` publishes `.sensing` before the first step, so a step
  /// list still has to give the UI turns to render it, and an empty list would
  /// complete the interpreter before the screen was ever drawn.
  private static func zeroPeersForeverSteps() -> [Step] {
    Array(repeating: Step.pause, count: 4)
  }

  /// Every observation lands in one demo window (`enin: 0`, no
  /// `advanceDemoWindow`) on purpose, and the scenario is unreadable without
  /// knowing why.
  ///
  /// No observation here resolves a display id, so `devicesVerified` never
  /// moves and the distinct-device arm of
  /// `BeidSharedKit.sensing.shouldConfirmScanEvent` can never fire. The only
  /// arm left is co-presence, which counts `demoWindowRpids` — and
  /// `advanceDemoWindow()` clears that set. A window advance placed anywhere
  /// inside this run would reset the count below the threshold, the event
  /// would never confirm, and the scenario would park in Event Found looking
  /// entirely plausible while never reaching the Recording screen it exists
  /// to show.
  ///
  /// Overshooting the threshold is the point rather than an accident: at
  /// exactly the threshold the diagnostic line reads the same as a healthy
  /// session that happened to confirm, and the state being demonstrated is
  /// the lopsided one.
  private static func unidentifiedHeavySteps() -> [Step] {
    let threshold = max(1, BeidConfig.eventConfirmThreshold)
    var steps: [Step] = [.pause]
    for index in 1...(threshold + 3) {
      steps.append(.observeOneUnidentifiedRpid(rpid: "unidentified-rpid-\(index)", enin: 0))
      steps.append(.applyPhaseDecision)
      steps.append(.pause)
    }
    return steps
  }
}
