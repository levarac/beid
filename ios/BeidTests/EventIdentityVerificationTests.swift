// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation
import XCTest
@testable import Beid

final class EventIdentityVerificationTests: XCTestCase {
  func testCanonicalEventIdAloneDoesNotVerifyAndReplacementPreservesRawFields() {
    let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let session = EventSession(
      id: "RAW-EVENT-CODE",
      name: "RAW-EVENT-CODE",
      venue: "A venue",
      canonicalEventIdHex: "0x\(String(repeating: "a", count: 64))",
      sessionID: sessionID
    )

    XCTAssertEqual(session.identityVerification, .notChecked)

    let verified = session.replacingIdentityVerification(.verified)
    XCTAssertEqual(verified.identityVerification, .verified)
    XCTAssertEqual(verified.id, session.id)
    XCTAssertEqual(verified.name, session.name)
    XCTAssertEqual(verified.venue, session.venue)
    XCTAssertEqual(verified.canonicalEventIdHex, session.canonicalEventIdHex)
    XCTAssertEqual(verified.sessionID, sessionID)
  }

  func testMapperUsesSuccessAndContextForVerified() {
    let result = EventIdentityVerificationResolution(
      isSuccess: true,
      context: NSObject(),
      errorCode: nil,
      errorMessage: nil
    )

    XCTAssertEqual(EventIdentityVerificationMapper.map(result), .verified)
  }

  func testMapperRejectsSuccessWithoutContextAsUnavailable() {
    let result = EventIdentityVerificationResolution(
      isSuccess: true,
      context: nil,
      errorCode: nil,
      errorMessage: "missing context"
    )

    XCTAssertEqual(EventIdentityVerificationMapper.map(result), .unavailable)
  }

  func testMapperMapsOnlyExactDefinitionNotFoundWireCodeToNotFound() {
    let notFound = EventIdentityVerificationResolution(
      isSuccess: false,
      context: nil,
      errorCode: "definition_not_found",
      errorMessage: "no definition"
    )
    let validityMismatch = EventIdentityVerificationResolution(
      isSuccess: false,
      context: nil,
      errorCode: "definition_validity_mismatch",
      errorMessage: "outside validity"
    )

    XCTAssertEqual(EventIdentityVerificationMapper.map(notFound), .notFound)
    XCTAssertEqual(EventIdentityVerificationMapper.map(validityMismatch), .unavailable)
  }

  func testMapperMapsOtherErrorsAndMalformedContextToUnavailable() {
    let error = EventIdentityVerificationResolution(
      isSuccess: false,
      context: nil,
      errorCode: "definition_http_error",
      errorMessage: "network failure"
    )
    let missingErrorCode = EventIdentityVerificationResolution(
      isSuccess: false,
      context: nil,
      errorCode: nil,
      errorMessage: nil
    )

    XCTAssertEqual(EventIdentityVerificationMapper.map(error), .unavailable)
    XCTAssertEqual(EventIdentityVerificationMapper.map(missingErrorCode), .unavailable)
  }

  func testMapperTreatsCancellationAsNoUiOutcome() {
    let cancelled = EventIdentityVerificationResolution(
      isSuccess: false,
      context: nil,
      errorCode: "cancelled",
      errorMessage: "cancelled"
    )

    XCTAssertNil(EventIdentityVerificationMapper.map(cancelled))
  }

  func testPhaseAndPendingBindingUpdateOnlyMatchingStableEventId() {
    let session = EventSession(
      id: "MATCHING-EVENT",
      name: "MATCHING-EVENT",
      venue: nil,
      canonicalEventIdHex: "0x\(String(repeating: "b", count: 64))"
    )
    let phase = ScanPhase.recording(event: session, peersVerified: 2)
    let pending = EventBindingState.pendingConnect(session)

    let updatedPhase = phase.updatingIdentityVerification(
      forEventID: session.id,
      to: .checking
    )
    let updatedPending = pending.updatingIdentityVerification(
      forEventID: session.id,
      to: .checking
    )

    guard case .recording(let phaseEvent, let count) = updatedPhase else {
      return XCTFail("expected recording phase")
    }
    guard case .pendingConnect(let pendingEvent) = updatedPending else {
      return XCTFail("expected pending binding state")
    }
    XCTAssertEqual(phaseEvent.identityVerification, .checking)
    XCTAssertEqual(pendingEvent.identityVerification, .checking)
    XCTAssertEqual(count, 2)
    XCTAssertEqual(
      phase.updatingIdentityVerification(forEventID: "OTHER-EVENT", to: .verified),
      phase
    )
    XCTAssertEqual(
      pending.updatingIdentityVerification(forEventID: "OTHER-EVENT", to: .verified),
      pending
    )
  }
}
