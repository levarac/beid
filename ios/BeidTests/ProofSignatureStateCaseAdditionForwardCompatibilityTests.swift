// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import XCTest
@testable import Beid

/// Proves gh#155's acceptance criterion 3 — "adding a case to
/// `ProofSignatureState`, old files must still be readable" — already holds
/// today with **no code change to `ProofSignatureState` itself**.
///
/// Swift's compiler-synthesized `Codable` for an enum with associated
/// values (SE-0295) encodes/decodes each case as a single-key
/// container keyed by the case name (e.g. `{"failed":{"reason":"x"}}`,
/// `{"notRequested":{}}`). Decoding dispatches only on the case-key
/// actually *present* in the payload it is given — it never enumerates
/// "all cases this type currently knows about" to reject unrecognized
/// keys. A file written before a case existed can therefore never contain
/// that case's key, so a *decoder* that later gains the case can always
/// still read it: there is nothing here for an enum-case addition to break.
///
/// This is deliberately NOT tested by decoding a fixture containing only
/// today's existing cases under today's real `ProofSignatureState` — that
/// would pass whether or not this tolerance exists, since nothing about
/// case addition is exercised. Instead, two structurally-mirroring
/// test-only enums are defined: `ProbeSignatureStateV1` (today's shape) and
/// `ProbeSignatureStateV2` (V1 plus one new case). A value is encoded under
/// V1 — genuinely produced by a type that lacks the new case — and decoded
/// as V2 — genuinely read by a type that has it. Only that shape proves
/// case addition doesn't break existing-case decoding.
@MainActor
final class ProofSignatureStateCaseAdditionForwardCompatibilityTests: XCTestCase {
  private enum ProbeSignatureStateV1: Codable, Equatable {
    case notRequested
    case deferred
    case failed(reason: String)
  }

  private enum ProbeSignatureStateV2: Codable, Equatable {
    case notRequested
    case deferred
    case failed(reason: String)
    case expiredProbeOnly // does not exist in V1 -- the point of this test
  }

  func testNoPayloadCaseEncodedUnderV1DecodesUnderV2() throws {
    let v1Value = ProbeSignatureStateV1.notRequested
    let data = try JSONEncoder().encode(v1Value)

    let v2Value = try JSONDecoder().decode(ProbeSignatureStateV2.self, from: data)

    XCTAssertEqual(v2Value, .notRequested)
  }

  func testAnotherNoPayloadCaseEncodedUnderV1DecodesUnderV2() throws {
    let v1Value = ProbeSignatureStateV1.deferred
    let data = try JSONEncoder().encode(v1Value)

    let v2Value = try JSONDecoder().decode(ProbeSignatureStateV2.self, from: data)

    XCTAssertEqual(v2Value, .deferred)
  }

  func testAssociatedValueCaseEncodedUnderV1DecodesUnderV2WithSamePayload() throws {
    let v1Value = ProbeSignatureStateV1.failed(reason: "wallet declined")
    let data = try JSONEncoder().encode(v1Value)

    let v2Value = try JSONDecoder().decode(ProbeSignatureStateV2.self, from: data)

    XCTAssertEqual(v2Value, .failed(reason: "wallet declined"))
  }
}
