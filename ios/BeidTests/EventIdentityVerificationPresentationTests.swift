// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest
@testable import Beid

final class EventIdentityVerificationPresentationTests: XCTestCase {
  func testNotCheckedSuppressesTheRow() {
    XCTAssertNil(EventIdentityVerificationPresentation.forStatus(.notChecked))
  }

  func testCheckingUsesProgressAndNeutralStatusCopy() {
    let presentation = try! XCTUnwrap(
      EventIdentityVerificationPresentation.forStatus(.checking)
    )

    XCTAssertEqual(presentation.messageKey, "event.identityVerification.checking")
    XCTAssertEqual(presentation.defaultMessage, "Checking event registry…")
    XCTAssertEqual(presentation.iconSystemName, "arrow.triangle.2.circlepath")
    XCTAssertEqual(
      presentation.statusAccessibilityIdentifier,
      "event-identity-verification-status-checking"
    )
    XCTAssertTrue(presentation.showsProgress)
    XCTAssertFalse(presentation.showsRetry)
    XCTAssertFalse(presentation.usesProofSeal)
  }

  func testVerifiedUsesProofSealWithoutAnEventName() {
    let presentation = try! XCTUnwrap(
      EventIdentityVerificationPresentation.forStatus(.verified)
    )

    XCTAssertEqual(presentation.messageKey, "event.identityVerification.verified")
    XCTAssertEqual(presentation.defaultMessage, "Event identity verified")
    XCTAssertEqual(presentation.iconSystemName, "checkmark.seal.fill")
    XCTAssertEqual(
      presentation.statusAccessibilityIdentifier,
      "event-identity-verification-status-verified"
    )
    XCTAssertFalse(presentation.showsProgress)
    XCTAssertFalse(presentation.showsRetry)
    XCTAssertTrue(presentation.usesProofSeal)
  }

  func testUnavailableAndNotFoundHaveDistinctNeutralRetryPresentations() {
    let unavailable = try! XCTUnwrap(
      EventIdentityVerificationPresentation.forStatus(.unavailable)
    )
    let notFound = try! XCTUnwrap(
      EventIdentityVerificationPresentation.forStatus(.notFound)
    )

    XCTAssertEqual(unavailable.messageKey, "event.identityVerification.unavailable")
    XCTAssertEqual(
      unavailable.defaultMessage,
      "Event registry is temporarily unavailable."
    )
    XCTAssertEqual(unavailable.iconSystemName, "questionmark.circle")
    XCTAssertEqual(
      unavailable.statusAccessibilityIdentifier,
      "event-identity-verification-status-unavailable"
    )
    XCTAssertTrue(unavailable.showsRetry)
    XCTAssertFalse(unavailable.usesProofSeal)

    XCTAssertEqual(notFound.messageKey, "event.identityVerification.notFound")
    XCTAssertEqual(
      notFound.defaultMessage,
      "No registry definition was found for this event."
    )
    XCTAssertEqual(notFound.iconSystemName, "questionmark.circle")
    XCTAssertEqual(
      notFound.statusAccessibilityIdentifier,
      "event-identity-verification-status-not-found"
    )
    XCTAssertTrue(notFound.showsRetry)
    XCTAssertFalse(notFound.usesProofSeal)
  }

  func testStatusRowsUseStableIdentifiersAndNoForbiddenOrOverclaimingCopy() {
    let presentations = [
      EventIdentityVerificationPresentation.forStatus(.checking),
      EventIdentityVerificationPresentation.forStatus(.verified),
      EventIdentityVerificationPresentation.forStatus(.unavailable),
      EventIdentityVerificationPresentation.forStatus(.notFound)
    ].compactMap { $0 }
    let forbiddenTerms = ["NFT", "token", "on-chain", "gas", "mint", "airdrop", "web3"]

    XCTAssertEqual(
      Set(presentations.map(\.statusAccessibilityIdentifier)).count,
      presentations.count
    )
    XCTAssertTrue(
      presentations.allSatisfy { presentation in
        let copy = "\(presentation.messageKey) \(presentation.defaultMessage)"
        return !forbiddenTerms.contains { copy.localizedCaseInsensitiveContains($0) }
      }
    )
    XCTAssertTrue(
      presentations.allSatisfy { presentation in
        !presentation.defaultMessage.localizedCaseInsensitiveContains("display name")
      }
    )
    XCTAssertEqual(
      EventIdentityVerificationPresentation.retryButtonKey,
      "event.identityVerification.retry"
    )
    XCTAssertEqual(
      EventIdentityVerificationPresentation.retryAccessibilityIdentifier,
      "event-identity-verification-retry"
    )
  }
}
