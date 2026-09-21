#if DEBUG
// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Barnard
import BarnardCore
import BeidSharedKit
import CryptoKit
import XCTest
@testable import Beid

/// Coverage for `ProductionVenueBundleVerifier` (beid#432) and the pure
/// `VenueBundleVerificationLogic` helpers it is built from.
///
/// The identity chain (`verifyVenueBundleIdentity` via `RegistryClient`)
/// cannot be exercised offline: `RegistryResolution`/`VenueBundleIdentity`
/// have Kotlin-`internal` constructors, so Swift can construct neither a
/// fake registry answer nor a fake identity, and `RegistryClient` itself has
/// no test-injectable transport reachable from Swift. Every existing
/// production registry consumer in `ios/Beid` (`RegistryEventIdentityVerificationSource`,
/// `RegistryEventJoinRegistry`) has the same limit. What IS tested here,
/// without a network, is real: the B005 signature/window/agreement logic
/// (using barnard's own real-signed producer fixture), every pure mapping
/// and arithmetic helper, and the two wiring paths that are genuinely
/// reachable offline (malformed bytes, unconfigured registry client).
@MainActor
final class ProductionVenueBundleVerifierTests: XCTestCase {

  func testEnvelopeOverlapNormalizesEachVerifiedCadenceToWallClockSeconds() {
    XCTAssertFalse(
      VenueBundleVerificationLogic.hasOverlappingEnvelopeIntervals([
        (start: 10, end: 20, eninSeconds: 2), // [20, 40)
        (start: 15, end: 16, eninSeconds: 1)  // [15, 16), adjacent in time
      ])
    )
    XCTAssertFalse(
      VenueBundleVerificationLogic.hasOverlappingEnvelopeIntervals([
        (start: 10, end: 20, eninSeconds: 2), // [20, 40)
        (start: 40, end: 50, eninSeconds: 1)  // [40, 50), half-open adjacent
      ])
    )
    XCTAssertTrue(
      VenueBundleVerificationLogic.hasOverlappingEnvelopeIntervals([
        (start: 10, end: 20, eninSeconds: 2), // [20, 40)
        (start: 19, end: 21, eninSeconds: 1)  // [19, 21), overlaps in time
      ])
    )
    XCTAssertTrue(
      VenueBundleVerificationLogic.hasOverlappingEnvelopeIntervals([
        (start: 10, end: 20, eninSeconds: 0)
      ]),
      "a non-positive cadence must fail closed"
    )
    XCTAssertTrue(
      VenueBundleVerificationLogic.hasOverlappingEnvelopeIntervals([
        (start: 10, end: 10, eninSeconds: 1)
      ]),
      "an empty interval must fail closed"
    )
    XCTAssertTrue(
      VenueBundleVerificationLogic.hasOverlappingEnvelopeIntervals([
        (start: Int64.max - 2, end: Int64.max - 1, eninSeconds: 1),
        (start: Int64.max - 1, end: Int64.max, eninSeconds: 2)
      ]),
      "wall clock normalization overflow must fail closed"
    )
  }

  func testProductionVerifierRejectsMixedCadenceAgainstFixedDefinition() async throws {
    let server = try LoopbackJSONRPCServer { body in RecordedVenueRegistryURLProtocol.responseData(for: body) }
    let endpoint = try await server.start()
    defer { server.stop() }
    let client = try XCTUnwrap(ExportedKotlinPackages.org.levarac.parallax.registry.createSepoliaRegistryClientWithRpcEndpoints(
      readerAddressHex: "0xd4852f8526a1555a1b2c34145f0ecda412a53c51",
      primaryEndpointUrl: endpoint.absoluteString, secondaryEndpointUrl: endpoint.absoluteString))
    defer { client.close() }
    let result = await ProductionVenueBundleVerifier(registryClient: client).importBundle(
      bundleBytes: Data(hex: Self.mixedCadenceBundleHex), handoffBytes: Data(hex: Self.mixedCadenceHandoffHex))
    guard case .rejected(let failure) = result else { return XCTFail("mixed cadence must reject: \(result)") }
    XCTAssertEqual(failure, .definitionRejected)
  }

  func testRealProducerEnvelopesWithDifferentCadencesUseWallClockIntervals() throws {
    let first = try Self.cadenceContainer(Self.cadenceTwoContainerHex)
    let adjacent = try Self.cadenceContainer(Self.cadenceOneAdjacentContainerHex)
    let overlap = try Self.cadenceContainer(Self.cadenceOneOverlapContainerHex)
    let firstVerified = try XCTUnwrap(BarnardB005EnvelopeV2.verify(
      container: first, currentEnin: 10, nameValidator: nameValidator
    ))
    let adjacentVerified = try XCTUnwrap(BarnardB005EnvelopeV2.verify(
      container: adjacent, currentEnin: 40, nameValidator: nameValidator
    ))
    let overlapVerified = try XCTUnwrap(BarnardB005EnvelopeV2.verify(
      container: overlap, currentEnin: 19, nameValidator: nameValidator
    ))
    XCTAssertEqual(firstVerified.eventId, adjacentVerified.eventId)
    XCTAssertEqual(firstVerified.eventId, overlapVerified.eventId)
    XCTAssertFalse(VenueBundleVerificationLogic.hasOverlappingEnvelopeIntervals([
      (start: firstVerified.validFromEnin, end: firstVerified.relayExpiresAtEnin,
       eninSeconds: Int64(firstVerified.eninSeconds)),
      (start: adjacentVerified.validFromEnin, end: adjacentVerified.relayExpiresAtEnin,
       eninSeconds: Int64(adjacentVerified.eninSeconds)),
    ]))
    XCTAssertTrue(VenueBundleVerificationLogic.hasOverlappingEnvelopeIntervals([
      (start: firstVerified.validFromEnin, end: firstVerified.relayExpiresAtEnin,
       eninSeconds: Int64(firstVerified.eninSeconds)),
      (start: overlapVerified.validFromEnin, end: overlapVerified.relayExpiresAtEnin,
       eninSeconds: Int64(overlapVerified.eninSeconds)),
    ]))
  }

  // MARK: - Real signed envelope fixture

  /// `container_hex`/`current_enin` from barnard's
  /// `test-vectors/venue-envelope-producer-fixture.txt`, generated by
  /// `VenueEnvelopeProducerTests.testWriteCrossLanguageFixture` against a
  /// REAL signing key and `BarnardCoreSigning.signRecoverable` -- not a
  /// hand-written vector. Verified independently against these bytes in this
  /// PR: registrar/anchor/nonce are 0xa1/0xa2/0xa3 repeated, one authority
  /// key, joinMode 0, eninSeconds 300, validFromEnin 6,000,000,
  /// validThroughEnin 6,000,010, relayExpiresAtEnin 6,000,004, display name
  /// "Venue Test Event", no delegation cert.
  private static let realContainerHex =
    "030000d601a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2" +
    "a2a2a2a2a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3010279be667e" +
    "f9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f8179800012c005b8d80005b8d8a005b8" +
    "d8402236c422fa9e53e281056656e75652054657374204576656e74000f02ac07c182b379723813bf05" +
    "46ce0991cc0d05022c49dd1c7068a2f22a0ffb29ad1ee643185f0f260459c2808aae5a1c871784bd93ff" +
    "4d8bc8b87f634596fe00"
  private static let realContainerCurrentEnin: Int64 = 6_000_001

  // Generated by the integrated VenueEnvelopeProducer at a3c176e, with the
  // same fixture authority/event and one ephemeral test scalar. These are raw
  // signed B005 containers, never BLE wrapped or published.
  private static let mixedCadenceBundleHex = "aa0101021a00aa36a703541284a559ce2e4ba7551a87a4fb66f34dcf9b017004541f2eb14790f1108a3e54d8eb3f65b89ad08ec4000558205d5891b92a9a6597aa2c58586fd2fdf3974f40f732b9a319ec9f3fc4d7ab31950601075820f1b4b54e6c911f1f02c1c9383c4914af56ffa3888ec28910f9f3204812276d7f085901cfd284583ea301382e03782d6170706c69636174696f6e2f766e642e6c6576617261632e6576656e742d646566696e6974696f6e2b63626f720448f5df3c6eefaf5217a0590147af01010258205d5891b92a9a6597aa2c58586fd2fdf3974f40f732b9a319ec9f3fc4d7ab319503541111111111111111111111111111111111111111045422222222222222222222222222222222222222220558203333333333333333333333333333333333333333333333333333333333333333065820cba59e50c7666ef2468a14f2e53f04decfd078933cd245a9a2d77532eb23b7000701085820000000000000000000000000000000000000000000000000000000000000000009582102c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee50a582050d8f3689f95e95c30be32dc4e516460dff139c088ab1117af0c1041882529490b782868747470733a2f2f6f70657261746f722e6578616d706c652f76312f6f62736572766174696f6e730c1a6b49c6480d1a6b49dee30e000f489adc61d60dda843e584094eef779498c16ebaadd4140158c70d1b4597467b86822247471696c2905f2c952f54a857b411de964c06cde727e007e00c12f500d321a574d22de5ad39436f709582aa301010281582102f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f903010a8258f4030000f0011111111111111111111111111111111111111111222222222222222222222222222222222222222233333333333333333333333333333333333333333333333333333333333333330102f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f900012c005b8d80005b8d82005b8d82029adc61d60dda843e2a4261726e6172642052656c617920436f6e666f726d616e6365204576656e742030313233343536373839009eebc135994ddf7ef3d3a1cc07c12b64e9cb180dd75e55fa49914f0173574f2364559abfefb09ff9d398964f3fd5a14f6f59a7890e289ba1c0f6a445c1f9227e0058f4030000f0011111111111111111111111111111111111111111222222222222222222222222222222222222222233333333333333333333333333333333333333333333333333333333333333330102f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f90000016b49d4586b49d45a6b49d45a029adc61d60dda843e2a4261726e6172642052656c617920436f6e666f726d616e6365204576656e74203031323334353637383900d388464f893e55518afd6b1897794c87bdfb246f397ad3177c3d17561bd02a9605c91695b1ca8238e0abc50b2d1163af22e148b7f647b18a8aeeec7b761e53b601"
  private static let mixedCadenceHandoffHex = "a601010258205d5891b92a9a6597aa2c58586fd2fdf3974f40f732b9a319ec9f3fc4d7ab3195031a00aa36a704541284a559ce2e4ba7551a87a4fb66f34dcf9b017005541f2eb14790f1108a3e54d8eb3f65b89ad08ec4000658204748d58d5366e163c837872cab072b64a950902b4dc6f48f9e45cc16ffc37472"

  private static let cadenceTwoContainerHex = "030000d601a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3010279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f817980000020000000a000000140000001402236c422fa9e53e281056656e75652054657374204576656e7400e345e08e2b76ffa06eab146b9a1415c30d12c440cf70138d8ddd2a9ec268a1954b55454fa7074838616476176137cbfe5393a9f55e83b97b74a257b9cc5788f700"
  private static let cadenceOneAdjacentContainerHex = "030000d601a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3010279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f8179800000100000028000000320000003202236c422fa9e53e281056656e75652054657374204576656e74004cb441e3bca0d3451ed369babf0e2cbe3fbc4d70871cd1e363263ec9c3a764746b4e967b12f5ad1362bd83fbc481653db8ad231389ded0a4e294eab9829d753a00"
  private static let cadenceOneOverlapContainerHex = "030000d601a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3010279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f8179800000100000013000000150000001502236c422fa9e53e281056656e75652054657374204576656e7400c2c813a79746d56782a825a27b8003cfbc63509aef750b537800b7adda164ecb63316ef63c1f923dddb99e7dd275c753b64e47026aded13a3a0333ea3e27fa6600"

  private static func cadenceContainer(_ hex: String) throws -> [UInt8] {
    try hexBytes(hex)
  }

  private static func realContainer() throws -> [UInt8] {
    try hexBytes(realContainerHex)
  }

  private static func hexBytes(_ hex: String) throws -> [UInt8] {
    var result: [UInt8] = []
    result.reserveCapacity(hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      result.append(try XCTUnwrap(UInt8(hex[index..<next], radix: 16)))
      index = next
    }
    return result
  }

  private let nameValidator = BarnardB005NativeDisplayNameNormalizer()

  // MARK: - Real B005 verification (production Barnard code, no shared/ involved)

  func testRealSignedEnvelopeVerifiesAtItsOwnCurrentEnin() throws {
    let container = try Self.realContainer()
    let verified = BarnardB005EnvelopeV2.verify(
      container: container, currentEnin: Self.realContainerCurrentEnin, nameValidator: nameValidator
    )
    let unwrapped = try XCTUnwrap(verified)
    XCTAssertEqual(unwrapped.validFromEnin, 6_000_000)
    XCTAssertEqual(unwrapped.relayExpiresAtEnin, 6_000_004)
    XCTAssertEqual(unwrapped.validThroughEnin, 6_000_010)
    XCTAssertEqual(unwrapped.eninSeconds, 300)
    XCTAssertEqual(unwrapped.eventDisplayName, "Venue Test Event")
    XCTAssertEqual(unwrapped.joinMode, 0)
  }

  /// Negative control: a mutated signature byte fails verification. This
  /// exercises pre-existing Barnard code, not code this PR adds; it is
  /// evidence for the verifier's reliance on `verify`, not a fail-then-pass
  /// test of new behavior.
  func testMutatedSignatureByteFailsVerification() throws {
    var container = try Self.realContainer()
    container[container.count - 1] ^= 0x01
    XCTAssertNil(
      BarnardB005EnvelopeV2.verify(
        container: container, currentEnin: Self.realContainerCurrentEnin, nameValidator: nameValidator
      )
    )
  }

  /// The terminal-ENIN constraint from the brief: `relayExpiresAtEnin` is
  /// EXCLUSIVE, so `currentEnin == relayExpiresAtEnin` must not verify.
  func testEnvelopeIsNotServableAtItsOwnRelayExpiryEnin() throws {
    let container = try Self.realContainer()
    XCTAssertNil(
      BarnardB005EnvelopeV2.verify(container: container, currentEnin: 6_000_004, nameValidator: nameValidator)
    )
    // One ENIN earlier is still inside the half-open window.
    XCTAssertNotNil(
      BarnardB005EnvelopeV2.verify(container: container, currentEnin: 6_000_003, nameValidator: nameValidator)
    )
  }

  // MARK: - registryAgreement (real crypto, hand-constructed definition -- no chain read)

  private func verifiedFixtureEnvelope() throws -> BarnardB005VerifiedEnvelope {
    try XCTUnwrap(BarnardB005EnvelopeV2.verify(
      container: Self.realContainer(), currentEnin: Self.realContainerCurrentEnin, nameValidator: nameValidator
    ))
  }

  func testRegistryAgreementAgreesWhenTheDefinitionContainsTheEnvelopesWindow() throws {
    let verified = try verifiedFixtureEnvelope()
    let definition = BarnardEventDefinitionV1(
      eventId: verified.eventId,
      keySetDigest: verified.keySetDigest,
      joinMode: verified.joinMode,
      eventCodeHash: verified.eventCodeHash,
      // [5,999,990, 6,000,010] at 300s/ENIN, matching the registry-side ENIN
      // conversion in BarnardB005EnvelopeV2.registryAgreement's own doc.
      validFromUnixSeconds: 1_799_997_000,
      validUntilUnixSeconds: 1_800_003_299
    )
    XCTAssertEqual(BarnardB005EnvelopeV2.registryAgreement(verified, definition: definition), .agrees)
  }

  func testRegistryAgreementMismatchesOnAForeignEventId() throws {
    let verified = try verifiedFixtureEnvelope()
    var foreignEventId = verified.eventId
    foreignEventId[0] ^= 0x01
    let definition = BarnardEventDefinitionV1(
      eventId: foreignEventId,
      keySetDigest: verified.keySetDigest,
      joinMode: verified.joinMode,
      eventCodeHash: verified.eventCodeHash,
      validFromUnixSeconds: 1_799_997_000,
      validUntilUnixSeconds: 1_800_003_299
    )
    guard case .mismatched(let fields) = BarnardB005EnvelopeV2.registryAgreement(verified, definition: definition)
    else { return XCTFail("expected a mismatch") }
    XCTAssertTrue(fields.contains(.EVENT_ID))
  }

  // MARK: - VenueBundleVerificationLogic: import failure code mapping

  func testImportFailureMapsEveryKnownIdentityCode() {
    let table: [(String, VenueImportFailure)] = [
      ("handoff_mismatch", .handoffMismatch),
      ("deployment_mismatch", .unsupportedDeployment),
      ("registry_unavailable", .registryUnavailable),
      ("registry_source_mismatch", .registrySourceMismatch),
      ("definition_not_registered", .anchoredRecordMissing),
      ("invalid_definition", .definitionRejected),
    ]
    for (code, expected) in table {
      XCTAssertEqual(VenueBundleVerificationLogic.importFailure(forIdentityCode: code), expected, code)
    }
  }

  func testImportFailureFailsClosedOnAnUnknownCode() {
    XCTAssertNil(VenueBundleVerificationLogic.importFailure(forIdentityCode: "some_future_code"))
  }

  // MARK: - VenueBundleVerificationLogic: serving block code mapping

  func testServingBlockIsAVerbatimRawValueLookupForEveryCase() {
    for reason in VenueServingBlock.allCases {
      XCTAssertEqual(VenueBundleVerificationLogic.servingBlock(forCode: reason.rawValue), reason)
    }
  }

  func testServingBlockFailsClosedOnAnUnknownCode() {
    XCTAssertNil(VenueBundleVerificationLogic.servingBlock(forCode: "someFutureBlockCode"))
  }

  // MARK: - VenueBundleVerificationLogic: join mode

  func testBarnardJoinModeMapsOpenAndGatedAndFailsClosedOnNil() {
    XCTAssertEqual(
      VenueBundleVerificationLogic.barnardJoinMode(
        ExportedKotlinPackages.org.levarac.parallax.registry.EventJoinMode.OPEN
      ), 0
    )
    XCTAssertEqual(
      VenueBundleVerificationLogic.barnardJoinMode(
        ExportedKotlinPackages.org.levarac.parallax.registry.EventJoinMode.GATED
      ), 1
    )
    XCTAssertNil(VenueBundleVerificationLogic.barnardJoinMode(nil))
  }

  // MARK: - VenueBundleVerificationLogic: definition projection

  /// `shared/`'s gated verdict maps to the native case that refuses to serve.
  ///
  /// The DECISION this used to make now lives in `shared/`
  /// (`classifyVenueDefinition`), exercised against real codec output by
  /// `VenueDefinitionClassificationTest`, which is where the "a gated
  /// definition carries no eventCodeHash" reasoning and the 8-byte check are
  /// now asserted. What is left on this side is the mapping, and that is what
  /// this tests. Reverting `definitionProjection(for:)`'s body to `.unusable`
  /// for every input turns this RED; see the PR body for the captured output.
  func testSharedGatedVerdictMapsToTheNativeRefusal() {
    XCTAssertEqual(
      VenueBundleVerificationLogic.definitionProjection(
        for: ExportedKotlinPackages.org.levarac.parallax.venue
          .VenueDefinitionClassification.GATED_REQUIRES_EXTERNAL_HASH
      ),
      .gatedUnsupported
    )
  }

  /// Every `shared/` verdict maps to exactly one native case, and no two
  /// collapse together. A mapping that sent two verdicts to the same native
  /// case would make a gated pack indistinguishable from a malformed one
  /// again, which is the defect this whole chain exists to prevent.
  func testEverySharedVerdictMapsToItsOwnNativeCase() {
    typealias Classification =
      ExportedKotlinPackages.org.levarac.parallax.venue.VenueDefinitionClassification
    let table: [(Classification, VenueBundleVerificationLogic.DefinitionProjection)] = [
      (.OPEN_WITH_EVENT_CODE_HASH, .open),
      (.GATED_REQUIRES_EXTERNAL_HASH, .gatedUnsupported),
      (.NO_USABLE_JOIN_DECLARATION, .unusable),
    ]
    for (verdict, expected) in table {
      XCTAssertEqual(VenueBundleVerificationLogic.definitionProjection(for: verdict), expected)
    }
    XCTAssertEqual(Set(table.map(\.1)).count, table.count, "two shared verdicts must not share one native case")
    // The table above is hand-written, so on its own it can only check the
    // cases it already mentions -- a case added in `shared/` would simply go
    // unlisted, and nothing else would catch it: Swift Export renders the
    // Kotlin enum as a class, so the compiler cannot demand exhaustiveness
    // either (see `definitionProjection(for:)`). Binding a future Android
    // consumer to the SAME decision is why this classification lives in
    // `shared/` at all, so an unnoticed divergence here would cost exactly
    // the guarantee the move was made to buy. The generated class conforms to
    // `CaseIterable`, so the type can be asked directly.
    XCTAssertEqual(
      Classification.allCases.count,
      table.count,
      "shared/ declares \(Classification.allCases.count) VenueDefinitionClassification cases but this native "
        + "mapping table covers \(table.count). Add the missing case to the table and to "
        + "VenueBundleVerificationLogic.definitionProjection(for:)."
    )
  }

  /// Import refuses a gated definition, with its own outcome.
  ///
  /// Before this, nothing was decided about join mode at import: every
  /// definition that verified was imported, and a gated one then failed at
  /// serving time as `envelopeRejected` -- a verdict about an envelope that
  /// had verified fine. Reverting `importFailure(forProjection:)` to that
  /// previous behaviour (`return nil` for every projection, i.e. import never
  /// decides on join mode) turns this RED; see the PR body for the captured
  /// output.
  func testImportRefusesAGatedDefinitionWithItsOwnOutcome() {
    XCTAssertEqual(
      VenueBundleVerificationLogic.importFailure(forProjection: .gatedUnsupported),
      .gatedEventUnsupported
    )
  }

  /// Import decides ONLY the gated case. An open event imports, and a
  /// definition that will not project for some other reason keeps the path it
  /// has always had -- refused at serving time, not relocated to import.
  func testImportDecidesOnlyTheGatedCaseAndRelocatesNoOtherRefusal() {
    XCTAssertNil(VenueBundleVerificationLogic.importFailure(forProjection: .open))
    XCTAssertNil(VenueBundleVerificationLogic.importFailure(forProjection: .unusable))
  }

  // MARK: - VenueBundleVerificationLogic: ENIN window arithmetic

  func testDefinitionEninWindowMatchesTheKnownFixtureConversion() {
    // shared/'s venue-current-lease-v1.json fixture: validFrom 1,799,997,000,
    // validUntil 1,800,003,299, eninSeconds 300 -> [5,999,990, 6,000,010].
    // Cross-checked independently in Python against
    // BarnardB005EnvelopeV2.registryAgreement's own formula before writing
    // this assertion.
    let window = VenueBundleVerificationLogic.definitionEninWindow(
      validFromUnixSeconds: 1_799_997_000, validUntilUnixSeconds: 1_800_003_299, eninSeconds: 300
    )
    XCTAssertEqual(window?.start, 5_999_990)
    XCTAssertEqual(window?.end, 6_000_010)
  }

  func testDefinitionEninWindowRejectsAMalformedWindow() {
    XCTAssertNil(VenueBundleVerificationLogic.definitionEninWindow(
      validFromUnixSeconds: 100, validUntilUnixSeconds: 50, eninSeconds: 300
    ))
    XCTAssertNil(VenueBundleVerificationLogic.definitionEninWindow(
      validFromUnixSeconds: 0, validUntilUnixSeconds: 100, eninSeconds: 0
    ))
    XCTAssertNil(VenueBundleVerificationLogic.definitionEninWindow(
      validFromUnixSeconds: -1, validUntilUnixSeconds: 100, eninSeconds: 300
    ))
  }

  func testFloorDivAndFloorModMatchKotlinSemanticsForNegativeInputs() {
    // Swift's native `/`/`%` truncate toward zero: -7 / 2 == -3, -7 % 2 ==
    // -1. Kotlin's floorDiv/floorMod round toward negative infinity:
    // floorDiv(-7, 2) == -4, floorMod(-7, 2) == 1. If this test used Swift's
    // operators directly it would assert the wrong numbers.
    XCTAssertEqual(VenueBundleVerificationLogic.floorDiv(-7, 2), -4)
    XCTAssertEqual(VenueBundleVerificationLogic.floorMod(-7, 2), 1)
    XCTAssertEqual(VenueBundleVerificationLogic.floorDiv(7, 2), 3)
    XCTAssertEqual(VenueBundleVerificationLogic.floorMod(7, 2), 1)
  }

  // MARK: - VenueBundleVerificationLogic: coverage-gap detection

  func testCoverageGapDetectsAMissingFutureSlice() {
    // Exactly the real producer fixture's situation: one envelope covering
    // only [6,000,000, 6,000,004) inside a wider required span.
    XCTAssertTrue(VenueBundleVerificationLogic.hasCoverageGap(
      candidates: [(6_000_000, 6_000_004)], requiredStart: 5_999_990, requiredEnd: 6_000_010
    ))
  }

  func testCoverageGapIsFalseWhenIntervalsExactlyTileTheRequiredSpan() {
    XCTAssertFalse(VenueBundleVerificationLogic.hasCoverageGap(
      candidates: [(5_999_990, 6_000_000), (6_000_000, 6_000_004), (6_000_004, 6_000_010)],
      requiredStart: 5_999_990, requiredEnd: 6_000_010
    ))
  }

  func testCoverageGapToleratesOverlapButNotAGap() {
    XCTAssertFalse(VenueBundleVerificationLogic.hasCoverageGap(
      candidates: [(5_999_990, 6_000_005), (6_000_003, 6_000_010)],
      requiredStart: 5_999_990, requiredEnd: 6_000_010
    ))
    XCTAssertTrue(VenueBundleVerificationLogic.hasCoverageGap(
      candidates: [(5_999_990, 6_000_003), (6_000_004, 6_000_010)],
      requiredStart: 5_999_990, requiredEnd: 6_000_010
    ))
  }

  func testCoverageGapNeverRequiresTheExclusiveTerminalEnin() {
    // requiredEnd itself (the definition's own inclusive last ENIN, +1) can
    // never be covered by construction (relayExpiresAtEnin <= validThroughEnin),
    // so a single envelope reaching exactly requiredEnd must be sufficient.
    XCTAssertFalse(VenueBundleVerificationLogic.hasCoverageGap(
      candidates: [(5_999_990, 6_000_010)], requiredStart: 5_999_990, requiredEnd: 6_000_010
    ))
  }

  // MARK: - coverageOutcome: fail closed, never a pass-through, when coverage is uncomputable

  /// "Could not determine coverage" must never read as "coverage is
  /// satisfied." Reverting `coverageOutcome` to the `if let ... else fall
  /// through to .covered` shape it replaced turns this RED: see the PR body
  /// for the captured output.
  func testCoverageOutcomeRefusesRatherThanPassingThroughWhenNothingVerified() {
    XCTAssertEqual(
      VenueBundleVerificationLogic.coverageOutcome(
        referenceEninSeconds: nil, validFromUnixSeconds: 0, validUntilUnixSeconds: 100, coverageIntervals: []
      ),
      .uncomputable
    )
  }

  func testCoverageOutcomeRefusesRatherThanPassingThroughWhenTheDefinitionWindowIsMalformed() {
    // validFrom > validUntil, despite a reference eninSeconds being
    // available from some verified envelope -- this must refuse, not fall
    // through as though coverage were satisfied.
    XCTAssertEqual(
      VenueBundleVerificationLogic.coverageOutcome(
        referenceEninSeconds: 300, validFromUnixSeconds: 100, validUntilUnixSeconds: 0, coverageIntervals: []
      ),
      .uncomputable
    )
  }

  func testCoverageOutcomeDistinguishesAGapFromFullCoverage() {
    XCTAssertEqual(
      VenueBundleVerificationLogic.coverageOutcome(
        referenceEninSeconds: 300, validFromUnixSeconds: 1_799_997_000, validUntilUnixSeconds: 1_800_003_299,
        coverageIntervals: [(6_000_000, 6_000_004)]
      ),
      .gap
    )
    XCTAssertEqual(
      VenueBundleVerificationLogic.coverageOutcome(
        referenceEninSeconds: 300, validFromUnixSeconds: 1_799_997_000, validUntilUnixSeconds: 1_800_003_299,
        coverageIntervals: [(5_999_990, 6_000_010)]
      ),
      .covered
    )
  }

  // MARK: - Phase-1 scope: why the coverage gate is not wired to a refusal

  /// The phase-1 scope claim, stated over the real producer fixture.
  ///
  /// This test passes both before and after the coverage gate was unwired,
  /// and is recorded as such rather than offered as fail-then-pass evidence:
  /// it asserts facts about the fixture, not about the call site. The call
  /// site itself is unreachable offline for the reason this class's header
  /// already gives -- `VenueBundleIdentity` (`VenueBundleIdentity.kt:17`) and
  /// `EventDefinition` (`EventDefinitionModels.kt:70`) both have Kotlin
  /// `internal` constructors, so Swift can construct neither input
  /// `evaluateCurrentLease` takes.
  ///
  /// What it does pin down is why the gate had to go. The single envelope
  /// barnard's producer actually emits IS servable at a current ENIN inside
  /// its own window, and the same envelope CANNOT tile the definition's whole
  /// validity window. Under the removed gate those two facts together refused
  /// the pack before `evaluateVenueCurrentLease` could issue a current permit
  /// or a `notStarted` recheck. The venue lane owner's 2026-09-10 ruling in
  /// `docs/plans/2026-09-10-venue-bundle-import.md` puts whole-window
  /// coverage in phase 2.
  func testTheRealProducerFixtureIsServableNowYetCannotTileItsOwnDefinitionWindow() throws {
    let verified = try verifiedFixtureEnvelope()
    // Servable at a current ENIN inside its window. This is the phase-1
    // claim: a current lease after real SDK verification at that ENIN.
    XCTAssertNotNil(BarnardB005EnvelopeV2.verify(
      container: try Self.realContainer(),
      currentEnin: Self.realContainerCurrentEnin,
      nameValidator: nameValidator
    ))
    // The same envelope, measured against the shared fixture's definition
    // window, is a coverage gap -- computed from the VERIFIED bounds rather
    // than from hand-written numbers.
    XCTAssertEqual(
      VenueBundleVerificationLogic.coverageOutcome(
        referenceEninSeconds: verified.eninSeconds,
        validFromUnixSeconds: 1_799_997_000,
        validUntilUnixSeconds: 1_800_003_299,
        coverageIntervals: [(verified.validFromEnin, verified.relayExpiresAtEnin)]
      ),
      .gap
    )
  }

  // MARK: - Wiring: reachable offline without a chain

  func testMalformedBundleBytesAreRejectedWithoutTouchingTheRegistry() async {
    let verifier = ProductionVenueBundleVerifier(registryClient: nil)
    let result = await verifier.importBundle(bundleBytes: Data([0xff, 0x00]), handoffBytes: Data([0xff, 0x00]))
    guard case .rejected(let failure) = result else { return XCTFail("expected a rejection") }
    XCTAssertEqual(failure, .malformedOrOutOfBounds)
  }

  /// Uses the shared fixture's real, well-formed bundle/handoff CBOR bytes
  /// (decode only checks shape and digest agreement between the two, never
  /// chain state) so this exercises the "decode succeeded, no registry
  /// client to ask" branch specifically -- distinct from the malformed-bytes
  /// test above, which never reaches the registry step at all.
  func testNoConfiguredRegistryClientRejectsImportAsRegistryUnavailable() async throws {
    let fixture = try VenueServingContractFixture.load()
    let verifier = ProductionVenueBundleVerifier(registryClient: nil)
    let result = await verifier.importBundle(
      bundleBytes: fixture.artifact.bundleBytes, handoffBytes: fixture.artifact.handoffBytes
    )
    guard case .rejected(let failure) = result else { return XCTFail("expected a rejection") }
    XCTAssertEqual(failure, .registryUnavailable)
  }

  func testEvaluateWithNoRegistryClientBlocksAsRegistryUnavailable() async throws {
    let fixture = try VenueServingContractFixture.load()
    let verifier = ProductionVenueBundleVerifier(registryClient: nil)
    let decision = await verifier.evaluate(fixture.imported(), clock: .available(unixSeconds: 1_800_000_000))
    guard case .blocked(let rejection) = decision else { return XCTFail("expected a block") }
    XCTAssertEqual(rejection.reason, .registryUnavailable)
  }

  func testEvaluateWithUnavailableClockBlocksBeforeTouchingTheRegistry() async throws {
    let fixture = try VenueServingContractFixture.load()
    // No registry client configured at all: if evaluate() reached the
    // registry step despite the clock being unavailable, this would still
    // report registryUnavailable, not clockUnavailable -- so this also
    // proves clock-unavailability is checked FIRST.
    let verifier = ProductionVenueBundleVerifier(registryClient: nil)
    let decision = await verifier.evaluate(fixture.imported(), clock: .unavailable)
    guard case .blocked(let rejection) = decision else { return XCTFail("expected a block") }
    XCTAssertEqual(rejection.reason, .clockUnavailable)
  }

  /// This crosses the real iOS production composition path: the production
  /// RegistryClient resolves a recorded registry response through its Darwin
  /// HTTP transport, shared verifies the signed bundle identity, and the
  /// production verifier derives the current lease. No Kotlin object is
  /// constructed by Swift; the only test seam is URLProtocol at the HTTP
  /// boundary used by the existing production client.
  func testProductionClientAndVerifierRejectIncompleteSignedFixture() async throws {
    let fixture = try VenueServingContractFixture.load()
    let server = try LoopbackJSONRPCServer { body in
      RecordedVenueRegistryURLProtocol.responseData(for: body)
    }
    let endpoint = try await server.start()
    defer { server.stop() }

    let client = try XCTUnwrap(
      ExportedKotlinPackages.org.levarac.parallax.registry.createSepoliaRegistryClientWithRpcEndpoints(
        readerAddressHex: "0xd4852f8526a1555a1b2c34145f0ecda412a53c51",
        primaryEndpointUrl: endpoint.absoluteString,
        secondaryEndpointUrl: endpoint.absoluteString
      )
    )
    defer { client.close() }
    let verifier = ProductionVenueBundleVerifier(registryClient: client)

    let importedResult = await verifier.importBundle(
      bundleBytes: fixture.artifact.bundleBytes,
      handoffBytes: fixture.artifact.handoffBytes
    )
    guard case .rejected(let failure) = importedResult else {
      return XCTFail("the incomplete signed fixture must reject, got \(importedResult); server=\(server.summary)")
    }
    XCTAssertEqual(failure, .definitionRejected)
  }

  func testProductionVerifierRejectsSignedBundleWithScheduleGapAtImport() async throws {
    let fixture = try XCTUnwrap(try VenueBundleConformanceFixture.loadAll().first { $0.name == "valid" })
    let server = try LoopbackJSONRPCServer { body in
      RecordedVenueRegistryURLProtocol.responseData(for: body)
    }
    let endpoint = try await server.start()
    defer { server.stop() }
    let client = try XCTUnwrap(
      ExportedKotlinPackages.org.levarac.parallax.registry.createSepoliaRegistryClientWithRpcEndpoints(
        readerAddressHex: "0xd4852f8526a1555a1b2c34145f0ecda412a53c51",
        primaryEndpointUrl: endpoint.absoluteString,
        secondaryEndpointUrl: endpoint.absoluteString
      )
    )
    defer { client.close() }

    let result = await ProductionVenueBundleVerifier(registryClient: client).importBundle(
      bundleBytes: fixture.bundle, handoffBytes: fixture.handoff
    )
    guard case .rejected(let failure) = result else {
      return XCTFail("a signed bundle with a schedule gap must reject at import: \(result); \(server.summary)")
    }
    XCTAssertEqual(failure, .definitionRejected)
  }

  func testProductionVerifierImportsAndPermitsFullScheduleBundle() async throws {
    let fixture = try VenueBundleConformanceFixture.loadFullSchedule()
    let server = try LoopbackJSONRPCServer { body in
      RecordedVenueRegistryURLProtocol.responseData(
        for: body,
        contextABIHex: RecordedVenueRegistryURLProtocol.fullScheduleContextABIHex
      )
    }
    let endpoint = try await server.start()
    defer { server.stop() }
    let client = try XCTUnwrap(
      ExportedKotlinPackages.org.levarac.parallax.registry.createSepoliaRegistryClientWithRpcEndpoints(
        readerAddressHex: "0xd4852f8526a1555a1b2c34145f0ecda412a53c51",
        primaryEndpointUrl: endpoint.absoluteString,
        secondaryEndpointUrl: endpoint.absoluteString
      )
    )
    defer { client.close() }
    let verifier = ProductionVenueBundleVerifier(registryClient: client)

    let importedResult = await verifier.importBundle(
      bundleBytes: fixture.bundle, handoffBytes: fixture.handoff
    )
    guard case .imported(let imported) = importedResult else {
      return XCTFail("a contiguous full-schedule bundle must import: \(importedResult)")
    }
    let decision = await verifier.evaluate(
      imported,
      clock: .available(unixSeconds: 1_790_294_401)
    )
    guard case .permitted(let permit) = decision else {
      return XCTFail("a contiguous full-schedule bundle must permit its first lease: \(decision)")
    }
    XCTAssertEqual(permit.identity.eventIdHex, fixture.eventId)
    XCTAssertEqual(permit.currentEnin, 5_967_648)
  }

  func testProductionClientAndVerifierRejectIncompleteFixtureAfterDelayedRegistryResponse() async throws {
    let fixture = try VenueServingContractFixture.load()
    let delay: UInt64 = 50_000_000
    let server = try LoopbackJSONRPCServer(responseDelayNanoseconds: delay) { body in
      RecordedVenueRegistryURLProtocol.responseData(for: body)
    }
    let endpoint = try await server.start()
    defer { server.stop() }

    let client = try XCTUnwrap(
      ExportedKotlinPackages.org.levarac.parallax.registry.createSepoliaRegistryClientWithRpcEndpoints(
        readerAddressHex: "0xd4852f8526a1555a1b2c34145f0ecda412a53c51",
        primaryEndpointUrl: endpoint.absoluteString,
        secondaryEndpointUrl: endpoint.absoluteString
      )
    )
    defer { client.close() }
    let verifier = ProductionVenueBundleVerifier(registryClient: client)
    let started = ContinuousClock.now
    let importedResult = await verifier.importBundle(
      bundleBytes: fixture.artifact.bundleBytes,
      handoffBytes: fixture.artifact.handoffBytes
    )
    let elapsed = started.duration(to: .now)
    guard case .rejected(let failure) = importedResult else {
      return XCTFail("delayed production registry response must still reject the incomplete fixture: \(importedResult); server=\(server.summary)")
    }
    XCTAssertEqual(failure, .definitionRejected)
    XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(90), "both production registry RPC responses must be delayed")
  }

  func testDelayedProductionRegistryThroughViewModelRejectsIncompleteFixtureBeforeServing() async throws {
    let fixture = try VenueServingContractFixture.load()
    let clock = LockedVenueTestClock(.available(unixSeconds: VenueServingContractFixture.currentUnixSeconds))
    // The production registry fixture's permit is two 300-second ENINs ahead
    // of the fixture clock; use the actual exclusive permit boundary rather
    // than the smaller unit-test contract fixture boundary.
    let deadline = VenueServingContractFixture.currentUnixSeconds + 600
    var requests = 0
    let requestLock = NSLock()
    let server = try LoopbackJSONRPCServer(
      responseDelayNanoseconds: 50_000_000,
      onRequest: {
        requestLock.lock(); requests += 1; let count = requests; requestLock.unlock()
        // The first two calls import the registry context. Move the clock
        // when evaluation begins so the VM's post-verification guard sees the
        // permit at its exclusive deadline and performs only one fresh retry.
        if count == 3 { clock.set(.available(unixSeconds: deadline)) }
      }
    ) { body in
      RecordedVenueRegistryURLProtocol.responseData(for: body)
    }
    let endpoint = try await server.start()
    defer { server.stop() }
    let client = try XCTUnwrap(
      ExportedKotlinPackages.org.levarac.parallax.registry.createSepoliaRegistryClientWithRpcEndpoints(
        readerAddressHex: "0xd4852f8526a1555a1b2c34145f0ecda412a53c51",
        primaryEndpointUrl: endpoint.absoluteString,
        secondaryEndpointUrl: endpoint.absoluteString
      )
    )
    defer { client.close() }

    let verifier = ProductionVenueBundleVerifier(registryClient: client)
    let ports = ScriptedVenuePorts()
    let acquisition = StubVenueArtifactAcquisition()
    acquisition.replies = [.artifact(fixture.artifact)]
    let expiry = FakeVenueExpiryScheduler()
    let model = VenueSignedServingViewModel(
      verifier: verifier,
      broadcasting: ports,
      acquisition: acquisition,
      store: VenuePublicArtifactStore(),
      clock: { clock.get() },
      expiry: expiry
    )

    await model.supply(
      bundleSource: URL(string: "https://venue.example/bundle")!,
      handoffSource: URL(string: "https://venue.example/handoff")!,
      sourceDescription: "venue.example"
    )
    XCTAssertEqual(model.status, .importRejected(.definitionRejected), "server=\(server.summary), requests=\(requests)")
    XCTAssertNil(ports.installedPermit, "server=\(server.summary), requests=\(requests)")
    XCTAssertEqual(requests, 3, "import performs the two registry reads before rejecting the incomplete fixture: \(server.summary)")
    XCTAssertFalse(expiry.isScheduled)
  }

  func testNativeVerifierRejectsIncompleteAndInvalidConformanceVariants() async throws {
    let variants = try VenueBundleConformanceFixture.loadAll()
    XCTAssertEqual(Set(variants.map(\.name)), ["valid", "foreign-event-id", "tampered-envelope", "overlapping-envelope"])
    for variant in variants {
      let server = try LoopbackJSONRPCServer { body in RecordedVenueRegistryURLProtocol.responseData(for: body) }
      let endpoint = try await server.start()
      defer { server.stop() }
      let client = try XCTUnwrap(ExportedKotlinPackages.org.levarac.parallax.registry.createSepoliaRegistryClientWithRpcEndpoints(
        readerAddressHex: "0xd4852f8526a1555a1b2c34145f0ecda412a53c51",
        primaryEndpointUrl: endpoint.absoluteString, secondaryEndpointUrl: endpoint.absoluteString))
      defer { client.close() }
      let verifier = ProductionVenueBundleVerifier(registryClient: client)
      let importedResult = await verifier.importBundle(bundleBytes: variant.bundle, handoffBytes: variant.handoff)
      switch variant.name {
      case "valid":
        guard case .rejected(let failure) = importedResult else { return XCTFail("phase-1 valid fixture must reject without full schedule coverage: \(importedResult); \(server.summary)") }
        XCTAssertEqual(failure, .definitionRejected)
      case "foreign-event-id":
        guard case .rejected(let failure) = importedResult else { return XCTFail("foreign must reject: \(importedResult); \(server.summary)") }
        XCTAssertEqual(failure, .definitionRejected)
      case "tampered-envelope":
        guard case .rejected(let failure) = importedResult else { return XCTFail("tampered must reject at import: \(importedResult); \(server.summary)") }
        XCTAssertEqual(failure, .definitionRejected)
      case "overlapping-envelope":
        guard case .rejected(let failure) = importedResult else { return XCTFail("overlap must reject: \(importedResult); \(server.summary)") }
        XCTAssertEqual(failure, .definitionRejected)
      default: XCTFail("unlisted variant \(variant.name)")
      }
    }
  }

  /// beid#597 — a link whose fragment was altered must be refused, and the refusal
  /// must come from the same handoff/bundle comparison the two-URL form ran.
  ///
  /// The handoff now travels in the fragment, which is the one part of a link a
  /// server never sees and therefore never validates. Nothing but this comparison
  /// stands between an altered fragment and a venue device serving for it, so the
  /// carrier change is only safe if a one-byte edit still fails here.
  func testAVenueLinkWithATamperedDigestFragmentIsRejectedByTheSameHandoffComparison() async throws {
    let valid = try XCTUnwrap(try VenueBundleConformanceFixture.loadAll().first { $0.name == "valid" })
    // The bundle digest is the handoff's last field, so its last byte is the last
    // byte of the encoding. Flipping it changes what the handoff claims about the
    // bundle without disturbing the CBOR the decoder reads.
    var tampered = valid.handoff
    tampered[tampered.index(before: tampered.endIndex)] ^= 0x01
    XCTAssertEqual(tampered.count, valid.handoff.count)
    XCTAssertNotEqual(tampered, valid.handoff)

    let link = "https://artifacts.example/venue-bundles/\(valid.eventId)#" + tampered
      .base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    // The link itself is well-formed: the shared decoder accepts it and returns the
    // altered bytes. A tampered fragment is not a malformed link, and reporting it
    // as one would tell an operator to retype a link that is not the problem.
    let carried = try XCTUnwrap(
      ExportedKotlinPackages.org.levarac.parallax.venue.decodeVenueHandoffLinkBytes(link: link))
    let carriedBytes = Data(VenueKotlinBytes.swiftBytes(carried))
    XCTAssertEqual(carriedBytes, tampered)

    let server = try LoopbackJSONRPCServer { body in RecordedVenueRegistryURLProtocol.responseData(for: body) }
    let endpoint = try await server.start()
    defer { server.stop() }
    let client = try XCTUnwrap(ExportedKotlinPackages.org.levarac.parallax.registry.createSepoliaRegistryClientWithRpcEndpoints(
      readerAddressHex: "0xd4852f8526a1555a1b2c34145f0ecda412a53c51",
      primaryEndpointUrl: endpoint.absoluteString, secondaryEndpointUrl: endpoint.absoluteString))
    defer { client.close() }
    let result = await ProductionVenueBundleVerifier(registryClient: client).importBundle(
      bundleBytes: valid.bundle, handoffBytes: carriedBytes)
    guard case .rejected(let failure) = result else {
      return XCTFail("a tampered digest must reject at import: \(result); \(server.summary)")
    }
    XCTAssertEqual(failure, .handoffMismatch)

    // The same bundle with the untampered fragment reaches the phase-2 coverage
    // gate, so the rejection above is specifically the digest mismatch.
    let untampered = await ProductionVenueBundleVerifier(registryClient: client).importBundle(
      bundleBytes: valid.bundle, handoffBytes: valid.handoff)
    guard case .rejected(let failure) = untampered else {
      return XCTFail("the untampered incomplete pair must reject: \(untampered); \(server.summary)")
    }
    XCTAssertEqual(failure, .definitionRejected)
  }

  func testNativeVerifierRejectsMixedValidAndTamperedBundleAtImport() async throws {
    let bundle = Bundle(for: Self.self)
    let bundleURL = try XCTUnwrap(bundle.url(
      forResource: "mixed-valid-tampered.venue-bundle", withExtension: "cbor",
      subdirectory: "venue-bundle-conformance"))
    let handoffURL = try XCTUnwrap(bundle.url(
      forResource: "mixed-valid-tampered.venue-handoff", withExtension: "cbor",
      subdirectory: "venue-bundle-conformance"))
    let bundleBytes = try Data(contentsOf: bundleURL)
    let handoffBytes = try Data(contentsOf: handoffURL)
    XCTAssertEqual(bundleBytes.count, 1339)
    XCTAssertEqual(handoffBytes.count, 123)
    XCTAssertEqual(SHA256.hash(data: bundleBytes).map { String(format: "%02x", $0) }.joined(),
                   "4a4e96126d6440c1519b309c58c9dd731694f6c95844854d5eb1faaf63fa4066")
    XCTAssertEqual(SHA256.hash(data: handoffBytes).map { String(format: "%02x", $0) }.joined(),
                   "1393cb35864becf3693f80f596cbff81a2e99260721c3e2a16ef07cf0a4bf564")
    let server = try LoopbackJSONRPCServer { body in RecordedVenueRegistryURLProtocol.responseData(for: body) }
    let endpoint = try await server.start()
    defer { server.stop() }
    let client = try XCTUnwrap(ExportedKotlinPackages.org.levarac.parallax.registry.createSepoliaRegistryClientWithRpcEndpoints(
      readerAddressHex: "0xd4852f8526a1555a1b2c34145f0ecda412a53c51",
      primaryEndpointUrl: endpoint.absoluteString, secondaryEndpointUrl: endpoint.absoluteString))
    defer { client.close() }
    let result = await ProductionVenueBundleVerifier(registryClient: client).importBundle(
      bundleBytes: bundleBytes, handoffBytes: handoffBytes)
    guard case .rejected(let failure) = result else { return XCTFail("mixed bundle must reject at import: \(result)") }
    XCTAssertEqual(failure, .definitionRejected)
  }

}

private extension Data {
  init(hex: String) {
    var bytes = [UInt8]()
    bytes.reserveCapacity(hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      bytes.append(UInt8(hex[index..<next], radix: 16)!)
      index = next
    }
    self.init(bytes)
  }
}

private final class LockedVenueTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var reading: VenueClockReading

  init(_ reading: VenueClockReading) { self.reading = reading }

  func set(_ reading: VenueClockReading) {
    lock.lock(); self.reading = reading; lock.unlock()
  }

  func get() -> VenueClockReading {
    lock.lock(); defer { lock.unlock() }
    return reading
  }
}

private struct VenueBundleConformanceFixture {
  let name: String
  let bundle: Data
  let handoff: Data
  let eventId: String

  static func loadAll() throws -> [Self] {
    let bundle = Bundle(for: ProductionVenueBundleVerifierTests.self)
    let manifestURL = try XCTUnwrap(bundle.url(
      forResource: "manifest", withExtension: "json", subdirectory: "venue-bundle-conformance"))
    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
    return try manifest.variants.map { item in
      let bundleURL = try XCTUnwrap(bundle.url(
        forResource: item.bundleFile.replacingOccurrences(of: ".cbor", with: ""),
        withExtension: "cbor", subdirectory: "venue-bundle-conformance"))
      let handoffURL = try XCTUnwrap(bundle.url(
        forResource: item.handoffFile.replacingOccurrences(of: ".cbor", with: ""),
        withExtension: "cbor", subdirectory: "venue-bundle-conformance"))
      let bundleBytes = try Data(contentsOf: bundleURL)
      let handoffBytes = try Data(contentsOf: handoffURL)
      XCTAssertEqual(bundleBytes.count, item.bytes, item.name)
      XCTAssertEqual(handoffBytes.count, item.handoffBytes, item.name)
      XCTAssertEqual(Self.sha256(bundleBytes), item.sha256, item.name)
      XCTAssertEqual(Self.sha256(handoffBytes), item.handoffSha256, item.name)
      return Self(name: item.name, bundle: bundleBytes, handoff: handoffBytes, eventId: item.eventId)
    }
  }

  static func loadFullSchedule() throws -> (bundle: Data, handoff: Data, eventId: String) {
    let bundle = Bundle(for: ProductionVenueBundleVerifierTests.self)
    let bundleURL = try XCTUnwrap(bundle.url(
      forResource: "full-schedule.venue-bundle", withExtension: "hex", subdirectory: "venue-bundle-conformance"))
    let handoffURL = try XCTUnwrap(bundle.url(
      forResource: "full-schedule.venue-handoff", withExtension: "hex", subdirectory: "venue-bundle-conformance"))
    let bundleHex = String(decoding: try Data(contentsOf: bundleURL), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let handoffHex = String(decoding: try Data(contentsOf: handoffURL), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return (
      Data(hex: bundleHex),
      Data(hex: handoffHex),
      "996ab4d7cd0785199b715e6ff004f41ef740ead3b3363602ce1cb14b812d1f94"
    )
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private struct Manifest: Decodable { let variants: [Variant] }
  private struct Variant: Decodable {
    let name: String
    let bundleFile: String
    let handoffFile: String
    let eventId: String
    let bytes: Int
    let sha256: String
    let handoffBytes: Int
    let handoffSha256: String
  }
}

/// Recorded responses for the production RegistryClient's two JSON-RPC calls.
/// The CBOR payload is the same registry context used by the signed venue
/// vector; it is wrapped in the ABI dynamic-bytes result expected by the
/// reader contract. The HTTP layer remains the production Darwin transport.
private final class RecordedVenueRegistryURLProtocol: URLProtocol {
  private static let contextABIHex =
    "0000000000000000000000000000000000000000000000000000000000000020" +
    "00000000000000000000000000000000000000000000000000000000000000b7" +
    "a3010102a40154111111111111111111111111111111111111111102542222222222222222222222222222222222222222035820cba59e50c7666ef2468a14f2e53f04decfd078933cd245a9a2d77532eb23b700041a6b49c26003a30101020103818601582000000000000000000000000000000000000000000000000000000000000000005820f1b4b54e6c911f1f02c1c9383c4914af56ffa3888ec28910f9f3204812276d7f1a6b49c6481a6b49dee31a6b49c3f0000000000000000000"

  static let fullScheduleContextABIHex =
    "0000000000000000000000000000000000000000000000000000000000000020" +
    "00000000000000000000000000000000000000000000000000000000000000b7" +
    "a3010102a40154df6986bbadd189309d52d437851c10e47ca02e200254d34c8acff6dbc4dc192e0712aa97b1c836770512" +
    "035820e8dab1e251bac55f04aa0316e67916b7fff99c15c9ee4e4f41ba44599b5bf223041a6ab4641803a3010102010381" +
    "86015820000000000000000000000000000000000000000000000000000000000000000058203440ccbda7e59782ff36f" +
    "7760275298ee2ebb71e994f11d4127fb1259efb5c2c1a6ab5b9801a6ab85c801a6ab46800000000000000000000"

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.scheme == "https"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let payload = String(data: Self.responseData(for: request.httpBody ?? Data()), encoding: .utf8)!
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: nil,
      headerFields: ["Content-Type": "application/json"]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(payload.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  static func responseData(for body: Data, contextABIHex: String = contextABIHex) -> Data {
    let text = String(data: body, encoding: .utf8) ?? ""
    if text.contains("eth_getBlockByNumber") {
      return Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"number\":\"0x2a\",\"hash\":\"0x2222222222222222222222222222222222222222222222222222222222222222\"}}".utf8)
    }
    return Data("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":\"0x\(contextABIHex)\"}".utf8)
  }
}
#endif
