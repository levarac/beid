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
    XCTAssertFalse(presentation.isVerified)
    XCTAssertEqual(
      presentation.statusAccessibilityIdentifier,
      "event-identity-verification-status-checking"
    )
    XCTAssertTrue(presentation.showsProgress)
    XCTAssertFalse(presentation.showsRetry)
  }

  func testVerifiedUsesVerifiedStateAndCopyWithoutAnEventName() {
    let presentation = try! XCTUnwrap(
      EventIdentityVerificationPresentation.forStatus(.verified)
    )

    XCTAssertEqual(presentation.messageKey, "event.identityVerification.verified")
    XCTAssertEqual(presentation.defaultMessage, "Event identity verified")
    XCTAssertTrue(presentation.isVerified)
    XCTAssertEqual(
      presentation.statusAccessibilityIdentifier,
      "event-identity-verification-status-verified"
    )
    XCTAssertFalse(presentation.showsProgress)
    XCTAssertFalse(presentation.showsRetry)
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
    XCTAssertFalse(unavailable.isVerified)
    XCTAssertEqual(
      unavailable.statusAccessibilityIdentifier,
      "event-identity-verification-status-unavailable"
    )
    XCTAssertTrue(unavailable.showsRetry)
    XCTAssertFalse(unavailable.showsProgress)

    XCTAssertEqual(notFound.messageKey, "event.identityVerification.notFound")
    XCTAssertEqual(
      notFound.defaultMessage,
      "No registry definition was found for this event."
    )
    XCTAssertFalse(notFound.isVerified)
    XCTAssertEqual(
      notFound.statusAccessibilityIdentifier,
      "event-identity-verification-status-not-found"
    )
    XCTAssertTrue(notFound.showsRetry)
    XCTAssertFalse(notFound.showsProgress)
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
