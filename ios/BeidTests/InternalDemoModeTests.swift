// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation
import XCTest
@testable import Beid

#if DEBUG || BEID_INTERNAL_DEMO
@MainActor
private final class InternalDemoCryptographySpy: SensingCryptography {
  private(set) var operationCount = 0

  func eventSigningPublicKey(eventCode _: String) -> Data {
    operationCount += 1
    return Data(repeating: 1, count: 33)
  }

  func ownerPublicKey() -> Data {
    operationCount += 1
    return Data(repeating: 2, count: 33)
  }

  func signWindowReport(eventCode _: String, bytes _: Data) -> SensingRecoverableSignature {
    operationCount += 1
    return SensingRecoverableSignature(r: Data(), s: Data(), v: 0)
  }

  func signSelfProof(
    eventIdHash _: Data,
    eventSigningPublicKey _: Data,
    eninStart _: UInt64,
    eninEnd _: UInt64
  ) -> SensingRecoverableSignature? {
    operationCount += 1
    return nil
  }

  func signWalletAcknowledgement(
    walletAddress _: Data,
    walletSignature _: Data
  ) -> SensingRecoverableSignature? {
    operationCount += 1
    return nil
  }
}

@MainActor
final class InternalDemoModeTests: XCTestCase {
  func testReservedCodeCanonicalizationIsTrimmedAndCaseFolded() {
    XCTAssertTrue(ReservedDemoEventCode.isReserved("  DEMO-APPREVIEWGOLDEN  "))
    XCTAssertFalse(ReservedDemoEventCode.isReserved("DEMO"))
    XCTAssertFalse(ReservedDemoEventCode.isReserved("real-demo-appreviewgolden"))
  }

  func testEverySupportedReservedCodeSelectsItsExactScenario() throws {
    let expected = [
      "demo-appReviewGolden": "appReviewGolden",
      "demo-crowdSurge": "crowdSurge",
      "demo-signalLostMidway": "signalLostMidway",
      "demo-longDisplayNames": "longDisplayNames",
    ]

    for (rawCode, identifier) in expected {
      guard case .scenario(let scenario) = ReservedDemoEventCode.classify(
        rawCode,
        executionEnabled: true
      ) else {
        XCTFail("expected supported scenario for \(rawCode)")
        continue
      }
      XCTAssertEqual(scenario.identifier, identifier)
    }
  }

  func testUnknownReservedCodeFailsLocally() {
    XCTAssertEqual(
      ReservedDemoEventCode.classify(" demo-not-a-scenario ", executionEnabled: true),
      .rejected
    )
  }

  func testReleasePolicyRejectsEvenAKnownReservedCode() {
    XCTAssertEqual(
      ReservedDemoEventCode.classify("demo-appReviewGolden", executionEnabled: false),
      .rejected
    )
  }

  func testReservedCodeIsInterceptedBeforeLookupAndBarnardJoin() async {
    let coordinator = AppCoordinator(registryClient: nil)
    var lookupInputs: [String] = []
    coordinator.resolveCanonicalEventIdHexOverride = { code in
      lookupInputs.append(code)
      return nil
    }

    let outcome = await coordinator.joinEventResolvingCanonicalId(
      code: "  DEMO-CROWDSURGE  "
    )

    XCTAssertEqual(outcome, .completed(nil))
    XCTAssertTrue(lookupInputs.isEmpty)
    XCTAssertNil(coordinator.sensingCoordinator.joinedEventCode)
    XCTAssertEqual(coordinator.sensingCoordinator.pendingDemoScenarioIdentifier, "crowdSurge")
  }

  func testUnknownReservedCodeDoesNotReachLookupOrBarnardJoin() async {
    let coordinator = AppCoordinator(registryClient: nil)
    var lookupCallCount = 0
    coordinator.resolveCanonicalEventIdHexOverride = { _ in
      lookupCallCount += 1
      return nil
    }

    let outcome = await coordinator.joinEventResolvingCanonicalId(code: "demo-unknown")

    XCTAssertEqual(outcome, .completed(.reservedDemoCodeUnavailable))
    XCTAssertEqual(lookupCallCount, 0)
    XCTAssertNil(coordinator.sensingCoordinator.joinedEventCode)
    XCTAssertNil(coordinator.sensingCoordinator.pendingDemoScenarioIdentifier)
  }

  func testBannerStatePersistsThroughScenarioCompletionSignalLossAndResumeThenClearsOnExit() async {
    let coordinator = makeIsolatedSensingCoordinator(for: self)
    coordinator.prepareReservedDemoScenario(.signalLostMidway)

    coordinator.startSensing()
    await coordinator.waitForDemoSequenceToFinish()

    XCTAssertEqual(coordinator.activeDemoScenarioIdentifier, "signalLostMidway")
    XCTAssertTrue(DemoBannerPresentation.isVisible(activeScenarioIdentifier: coordinator.activeDemoScenarioIdentifier))
    guard case .signalLost = coordinator.phase else {
      XCTFail("expected signal-lost checkpoint, got \(coordinator.phase)")
      return
    }

    coordinator.resumeSensing()
    await coordinator.waitForDemoSequenceToFinish()

    XCTAssertEqual(coordinator.activeDemoScenarioIdentifier, "signalLostMidway")
    XCTAssertTrue(DemoBannerPresentation.isVisible(activeScenarioIdentifier: coordinator.activeDemoScenarioIdentifier))

    coordinator.reset()

    XCTAssertNil(coordinator.activeDemoScenarioIdentifier)
    XCTAssertNil(coordinator.pendingDemoScenarioIdentifier)
    XCTAssertFalse(DemoBannerPresentation.isVisible(activeScenarioIdentifier: coordinator.activeDemoScenarioIdentifier))
  }

  func testEveryReservedScenarioHasZeroCryptographyOrProofEffects() async {
    for scenario in DemoScenario.allScenarios {
      let cryptography = InternalDemoCryptographySpy()
      let coordinator = makeIsolatedSensingCoordinator(
        for: self,
        sensingCryptography: cryptography
      )
      var collectedProofCount = 0
      coordinator.onProofCollected = { _ in collectedProofCount += 1 }
      coordinator.prepareReservedDemoScenario(scenario)

      coordinator.startSensing()
      await coordinator.waitForDemoSequenceToFinish()
      while coordinator.hasParkedDemoScenarioForTesting {
        coordinator.resumeSensing()
        await coordinator.waitForDemoSequenceToFinish()
      }
      let selfProof = coordinator.stopSensing()

      XCTAssertEqual(cryptography.operationCount, 0, scenario.identifier)
      XCTAssertEqual(collectedProofCount, 0, scenario.identifier)
      XCTAssertNil(selfProof, scenario.identifier)
    }
  }
}
#endif
