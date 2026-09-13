// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

#if DEBUG
import CryptoKit
import Foundation
import XCTest
@testable import Beid

private final class VenueServingFixtureBundle: NSObject {}

/// Both the future real-provider tests and the consumer/fake harness use this
/// same artifact. The immutable source hash and literal expected facts are
/// independent of production constants or the future verifier's output.
struct VenueServingContractFixture {
  static let currentUnixSeconds: Int64 = 1_800_000_000
  static let currentEnin: Int64 = 6_000_000
  static let exclusiveStopUnixSeconds: Int64 = 1_800_000_300
  static let eventIdHex = "5d5891b92a9a6597aa2c58586fd2fdf3974f40f732b9a319ec9f3fc4d7ab3195"
  static let bundleDigestHex = "e31c1bf3777936e004b5f501fbbb1aa73ac01c42bf83a6256d98bd13242c7f21"
  static let payloadDigestHex = "76e7eef6d62a7d5bab62ca1daf19561da6ee2a78b9d2247cadcb82a17b31f437"
  static let displayName = "Barnard Relay Conformance Event 0123456789 abcdefghijklmno"

  let artifact: VenuePublicArtifact
  let container: Data

  var identity: VenueArtifactIdentity {
    VenueArtifactIdentity(eventIdHex: Self.eventIdHex, definitionSequence: 1, bundleDigestHex: Self.bundleDigestHex)
  }

  func imported() -> VenueImportedBundle {
    VenueServingContractTestFactory.imported(identity: identity, publicArtifact: artifact)
  }

  func permit() -> VenueServePermit {
    VenueServingContractTestFactory.permit(
      identity: identity,
      container: container,
      displayName: Self.displayName,
      payloadDigestHex: Self.payloadDigestHex,
      currentEnin: Self.currentEnin,
      // The fixture's own ENIN span: currentEnin 6,000,000 at 300s is
      // [1,800,000,000, 1,800,000,300), so the start is the vector's
      // `currentEpochSeconds` and the stop is one ENIN later.
      startAtUnixSeconds: Self.currentUnixSeconds,
      stopAtUnixSeconds: Self.exclusiveStopUnixSeconds
    )
  }

  static func load() throws -> Self {
    let url = try XCTUnwrap(
      Bundle(for: VenueServingFixtureBundle.self).url(forResource: "venue-current-lease-v1", withExtension: "json")
    )
    let bytes = try Data(contentsOf: url)
    XCTAssertEqual(
      SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
      "33c907eeb6296701e477c779a6fdd41697b11d7b2f7980fa89aa001eecd13f01"
    )
    let decoded = try JSONDecoder().decode(Vector.self, from: bytes)
    XCTAssertEqual(decoded.currentEpochSeconds, currentUnixSeconds)
    XCTAssertEqual(decoded.currentEnin, currentEnin)
    XCTAssertEqual(decoded.authorityDirect.bundleDigestHex, bundleDigestHex)
    return Self(
      artifact: VenuePublicArtifact(
        bundleBytes: try hexBytes(decoded.authorityDirect.bundleHex),
        handoffBytes: try hexBytes(decoded.authorityDirect.handoffHex)
      ),
      container: try hexBytes(decoded.authorityDirect.sourceContainerHex)
    )
  }

  private struct Vector: Decodable {
    let currentEpochSeconds: Int64
    let currentEnin: Int64
    let authorityDirect: AuthorityDirect
  }

  private struct AuthorityDirect: Decodable {
    let bundleHex: String
    let handoffHex: String
    let sourceContainerHex: String
    let bundleDigestHex: String
  }

  private static func hexBytes(_ value: String) throws -> Data {
    let characters = Array(value)
    guard characters.count % 2 == 0 else { throw CocoaError(.fileReadCorruptFile) }
    var result = Data()
    for offset in stride(from: 0, to: characters.count, by: 2) {
      let byte = try XCTUnwrap(UInt8(String(characters[offset...offset + 1]), radix: 16))
      result.append(byte)
    }
    return result
  }
}

/// Call with OBSERVED outcomes, never prefilled allCases. Both the real-provider
/// tests and the scripted fake must satisfy the same compiler-derived inventory.
func assertVenueOutcomeCoverage(
  imports: Set<VenueImportFailure>,
  serving: Set<VenueServingBlock>,
  radio: Set<VenueRadioState>,
  radioFailures: Set<VenueRadioFailure>,
  file: StaticString = #filePath,
  line: UInt = #line
) {
  XCTAssertEqual(imports, Set(VenueImportFailure.allCases), file: file, line: line)
  XCTAssertEqual(serving, Set(VenueServingBlock.allCases), file: file, line: line)
  XCTAssertEqual(radio, Set(VenueRadioState.allCases), file: file, line: line)
  XCTAssertEqual(radioFailures, Set(VenueRadioFailure.allCases), file: file, line: line)
}
#endif
