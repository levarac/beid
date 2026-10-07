// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BarnardCore
import BeidSharedKit
import CryptoKit
import Foundation
import Network
import XCTest
@testable import Beid

@MainActor
private final class StaticEventDefinitionContextProvider: EventDefinitionContextProvider {
  private let verified: VerifiedSubmissionDefinition

  init(configuration: ExportedKotlinPackages.org.levarac.parallax.submission
    .SubmissionOperatorConfiguration) {
    verified = VerifiedSubmissionDefinition(configuration: configuration)
  }

  func resolve(
    eventIdHex: String,
    completion: @escaping (VerifiedSubmissionDefinition?) -> Void
  ) {
    completion(verified)
  }
}

@MainActor
private final class DeferredEventDefinitionContextProvider: EventDefinitionContextProvider {
  private let verified: VerifiedSubmissionDefinition
  private(set) var requestedEventIds: [String] = []
  private var completions: [(VerifiedSubmissionDefinition?) -> Void] = []

  init(configuration: ExportedKotlinPackages.org.levarac.parallax.submission
    .SubmissionOperatorConfiguration) {
    verified = VerifiedSubmissionDefinition(configuration: configuration)
  }

  func resolve(
    eventIdHex: String,
    completion: @escaping (VerifiedSubmissionDefinition?) -> Void
  ) {
    requestedEventIds.append(eventIdHex)
    completions.append(completion)
  }

  func resolveAll() {
    let pending = completions
    completions.removeAll()
    pending.forEach { $0(verified) }
  }
}

@MainActor
private final class RecordingRegistryLookup {
  private let verified: VerifiedSubmissionDefinition
  private(set) var requestedEventIds: [String] = []

  init(configuration: ExportedKotlinPackages.org.levarac.parallax.submission
    .SubmissionOperatorConfiguration) {
    verified = VerifiedSubmissionDefinition(configuration: configuration)
  }

  func resolve(
    eventIdHex: String,
    completion: @escaping (VerifiedSubmissionDefinition?) -> Void
  ) {
    requestedEventIds.append(eventIdHex)
    DispatchQueue.main.async { [verified] in
      completion(verified)
    }
  }
}

private final class TestSensingCryptography: SensingCryptography {
  private let publicKey = Data([
    0x02, 0x79, 0xbe, 0x66, 0x7e, 0xf9, 0xdc, 0xbb, 0xac, 0x55, 0xa0,
    0x62, 0x95, 0xce, 0x87, 0x0b, 0x07, 0x02, 0x9b, 0xfc, 0xdb, 0x2d,
    0xce, 0x28, 0xd9, 0x59, 0xf2, 0x81, 0x5b, 0x16, 0xf8, 0x17, 0x98
  ])

  func eventSigningPublicKey(eventCode: String) -> Data {
    publicKey
  }

  func ownerPublicKey() throws -> Data {
    publicKey
  }

  func signWindowReport(
    eventCode: String,
    bytes: Data
  ) -> SensingRecoverableSignature {
    let digest = Data(SHA256.hash(data: bytes))
    let signature = TestSecp256k1.sign(messageHash: digest, privateScalar: 1)
    return SensingRecoverableSignature(
      r: signature.r,
      s: signature.s,
      v: 0
    )
  }

  func signSelfProof(
    eventIdHash: Data,
    eventSigningPublicKey: Data,
    eninStart: UInt64,
    eninEnd: UInt64
  ) throws -> SensingRecoverableSignature? {
    nil
  }

  func signWalletAcknowledgement(
    walletAddress: Data,
    walletSignature: Data
  ) throws -> SensingRecoverableSignature? {
    nil
  }
}

/// Small test-only secp256k1 signer for private scalars 1, 2, and 3.
///
/// The fixed nonce k=1 makes R=G, so r is the generator x-coordinate and
/// s = hash + r*d (mod n). It is a valid ECDSA signature, but deliberately
/// unsuitable for production because the nonce is public and reused. Keeping
/// this here avoids making the in-process HTTP integration suite benchmark the
/// repository's pure-Swift field inversion; production signing remains in
/// Barnard.
private enum TestSecp256k1 {
  private static let generatorX: [UInt8] = [
    0x79, 0xbe, 0x66, 0x7e, 0xf9, 0xdc, 0xbb, 0xac,
    0x55, 0xa0, 0x62, 0x95, 0xce, 0x87, 0x0b, 0x07,
    0x02, 0x9b, 0xfc, 0xdb, 0x2d, 0xce, 0x28, 0xd9,
    0x59, 0xf2, 0x81, 0x5b, 0x16, 0xf8, 0x17, 0x98
  ]
  private static let curveOrder: [UInt8] = [
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe,
    0xba, 0xae, 0xdc, 0xe6, 0xaf, 0x48, 0xa0, 0x3b,
    0xbf, 0xd2, 0x5e, 0x8c, 0xd0, 0x36, 0x41, 0x41
  ]
  private static let halfOrder: [UInt8] = [
    0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0x5d, 0x57, 0x6e, 0x73, 0x57, 0xa4, 0x50, 0x1d,
    0xdf, 0xe9, 0x2f, 0x46, 0x68, 0x1b, 0x20, 0xa0
  ]

  static func sign(
    messageHash: Data,
    privateScalar: UInt8
  ) -> (r: Data, s: Data) {
    precondition(messageHash.count == 32)
    precondition((1...3).contains(privateScalar))
    let modulus = [UInt8](repeating: 0, count: 1) + curveOrder
    var sum = [UInt8](repeating: 0, count: 33)
    add(&sum, multiplied(generatorX, by: privateScalar))
    add(&sum, [UInt8](repeating: 0, count: 1) + Array(messageHash))
    while compare(sum, modulus) >= 0 {
      sum = subtract(sum, modulus)
    }

    var s = Array(sum.suffix(32))
    if compare(s, halfOrder) > 0 {
      s = Array(subtract(modulus, [UInt8](repeating: 0, count: 1) + s).suffix(32))
    }
    return (Data(generatorX), Data(s))
  }

  private static func multiplied(_ value: [UInt8], by scalar: UInt8) -> [UInt8] {
    var result = [UInt8](repeating: 0, count: 33)
    var carry = 0
    for index in stride(from: value.count - 1, through: 0, by: -1) {
      let product = Int(value[index]) * Int(scalar) + carry
      result[index + 1] = UInt8(product & 0xff)
      carry = product >> 8
    }
    result[0] = UInt8(carry)
    return result
  }

  private static func add(_ left: inout [UInt8], _ right: [UInt8]) {
    var carry = 0
    for index in stride(from: left.count - 1, through: 0, by: -1) {
      let sum = Int(left[index]) + Int(right[index]) + carry
      left[index] = UInt8(sum & 0xff)
      carry = sum >> 8
    }
    precondition(carry == 0)
  }

  private static func subtract(_ left: [UInt8], _ right: [UInt8]) -> [UInt8] {
    precondition(compare(left, right) >= 0)
    var result = left
    var borrow = 0
    for index in stride(from: left.count - 1, through: 0, by: -1) {
      let difference = Int(left[index]) - Int(right[index]) - borrow
      if difference < 0 {
        result[index] = UInt8(difference + 256)
        borrow = 1
      } else {
        result[index] = UInt8(difference)
        borrow = 0
      }
    }
    precondition(borrow == 0)
    return result
  }

  private static func compare(_ left: [UInt8], _ right: [UInt8]) -> Int {
    for (l, r) in zip(left, right) where l != r {
      return l < r ? -1 : 1
    }
    return 0
  }
}

/// A real loopback HTTP operator. It accepts the exact POST body and creates
/// a valid COSE AcceptanceReceipt from that body, so the normal test runs the
/// same URLSession/shared-client/runtime/store path as production.
private final class StubOperatorServer {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "beid.tests.stub-operator")
  private let lock = NSLock()
  private let eventId: Data
  private let signingPrivateKey: [UInt8]
  private let signingPublicKey: Data
  private var receipt: Data?
  private var startupError: Error?
  private var isReady = false
  private var isStopped = false
  private var connections: [ObjectIdentifier: NWConnection] = [:]
  private var connectionCount = 0
  private var receivedByteCount = 0
  private var requestCount = 0
  private let transientPostFailures: Int
  private var _postCount = 0
  private var _getCount = 0
  private var _postBodies: [Data] = []
  private var holdResponses: Bool
  private var heldResponses: [(NWConnection, Data)] = []
  private var activeRequests = 0
  private var maximumActiveRequests = 0

  var maximumInFlight: Int { lock.withLock { maximumActiveRequests } }

  func holdNewResponses() { queue.sync { holdResponses = true } }

  func releaseResponses() {
    queue.sync {
      holdResponses = false
      let responses = heldResponses
      heldResponses.removeAll()
      for (connection, wire) in responses { send(wire, on: connection) }
    }
  }

  var postCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return _postCount
  }

  var getCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return _getCount
  }

  var postBodies: [Data] {
    lock.lock()
    defer { lock.unlock() }
    return _postBodies
  }

  var diagnostics: String {
    lock.lock()
    defer { lock.unlock() }
    return "connections=\(connectionCount), bytes=\(receivedByteCount), requests=\(requestCount), POST=\(_postCount), GET=\(_getCount)"
  }

  init(
    eventId: Data,
    signingPrivateKey: [UInt8],
    signingPublicKey: Data,
    transientPostFailures: Int = 0,
    holdResponses: Bool = false
  ) throws {
    self.eventId = eventId
    self.signingPrivateKey = signingPrivateKey
    self.signingPublicKey = signingPublicKey
    self.transientPostFailures = transientPostFailures
    self.holdResponses = holdResponses
    listener = try NWListener(using: .tcp, on: .any)
  }

  func start() async throws -> URL {
    listener.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      self.lock.lock()
      defer { self.lock.unlock() }
      if case .ready = state {
        self.isReady = true
      }
      if case .failed(let error) = state {
        self.startupError = error
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      self?.accept(connection)
    }
    listener.start(queue: queue)

    for _ in 0..<100 {
      let status = lock.withLock { (isReady, startupError) }
      if let error = status.1 {
        throw error
      }
      if status.0, let port = listener.port, port.rawValue != 0 {
        return try XCTUnwrap(URL(string: "http://127.0.0.1:\(port.rawValue)"))
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw StubOperatorError.startTimedOut(diagnostics: diagnostics)
  }

  func stop() {
    listener.cancel()
    queue.sync {
      isStopped = true
      for connection in connections.values { connection.cancel() }
      connections.removeAll()
    }
  }

  func waitFor(postCount expectedPosts: Int, getCount expectedGets: Int? = nil) async throws {
    for _ in 0..<1_000 {
      if postCount >= expectedPosts,
         expectedGets.map({ getCount >= $0 }) ?? true {
        return
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw StubOperatorError.requestTimedOut(diagnostics: diagnostics)
  }

  private func accept(_ connection: NWConnection) {
    guard !isStopped else { connection.cancel(); return }
    connections[ObjectIdentifier(connection)] = connection
    lock.withLock { connectionCount += 1 }
    connection.stateUpdateHandler = { [weak self, weak connection] state in
      guard let self, let connection else { return }
      switch state {
      case .cancelled, .failed:
        self.connections.removeValue(forKey: ObjectIdentifier(connection))
      default:
        break
      }
    }
    connection.start(queue: queue)
    receive(connection, bytes: Data())
  }

  private func receive(_ connection: NWConnection, bytes: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
      [weak self, weak connection] data, _, isComplete, error in
      guard let self, let connection else { return }
      if let error {
        connection.cancel()
        self.record(error)
        return
      }

      var accumulated = bytes
      if let data {
        self.lock.withLock { self.receivedByteCount += data.count }
        accumulated.append(data)
      }
      if let request = self.parseRequest(accumulated) {
        self.respond(to: request, on: connection)
      } else if isComplete {
        connection.cancel()
      } else {
        self.receive(connection, bytes: accumulated)
      }
    }
  }

  private func respond(to request: HTTPRequest, on connection: NWConnection) {
    lock.withLock {
      requestCount += 1
      activeRequests += 1
      maximumActiveRequests = max(maximumActiveRequests, activeRequests)
    }
    let response: (status: Int, body: Data, contentType: String?)
    if request.method == "POST", request.path == "/v1/observations" {
      lock.lock()
      _postCount += 1
      _postBodies.append(request.body)
      let shouldFail = _postCount <= transientPostFailures
      lock.unlock()
      if shouldFail {
        response = (503, Data(), nil)
      } else {
        let generated = makeReceipt(observationBytes: request.body)
        lock.withLock { receipt = generated }
        response = (201, generated, "application/vnd.levarac.acceptance-receipt+cose")
      }
    } else if request.method == "GET", request.path.hasSuffix("/acceptance") {
      lock.lock()
      _getCount += 1
      let storedReceipt = receipt
      lock.unlock()
      if let storedReceipt {
        response = (200, storedReceipt, "application/vnd.levarac.acceptance-receipt+cose")
      } else {
        response = (404, Data(), nil)
      }
    } else {
      response = (404, Data(), nil)
    }

    var headers = "HTTP/1.1 \(response.status) \(response.status == 200 || response.status == 201 ? "OK" : "Not Found")\r\n"
    if let contentType = response.contentType {
      headers += "Content-Type: \(contentType)\r\n"
    }
    headers += "Content-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
    var wire = Data(headers.utf8)
    wire.append(response.body)
    if holdResponses {
      heldResponses.append((connection, wire))
    } else {
      send(wire, on: connection)
    }
  }

  private func send(_ wire: Data, on connection: NWConnection) {
    connection.send(content: wire, completion: .contentProcessed { [weak self] _ in
      self?.lock.withLock { self?.activeRequests -= 1 }
      connection.cancel()
    })
  }

  private func parseRequest(_ bytes: Data) -> HTTPRequest? {
    let separator = Data([13, 10, 13, 10])
    guard let headerRange = bytes.range(of: separator) else { return nil }
    let header = String(decoding: bytes[..<headerRange.lowerBound], as: UTF8.self)
    let lines = header.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return nil }
    let requestParts = requestLine.split(separator: " ")
    guard requestParts.count >= 2 else { return nil }
    let contentLength = lines.dropFirst().first { line in
      line.lowercased().hasPrefix("content-length:")
    }.flatMap { line in
      guard let value = line.split(separator: ":", maxSplits: 1).last else {
        return nil
      }
      return Int(String(value).trimmingCharacters(in: .whitespacesAndNewlines))
    } ?? 0
    let bodyStart = headerRange.upperBound
    guard bytes.count >= bodyStart + contentLength else { return nil }
    return HTTPRequest(
      method: String(requestParts[0]),
      path: String(requestParts[1]),
      body: Data(bytes[bodyStart..<(bodyStart + contentLength)])
    )
  }

  private func makeReceipt(observationBytes: Data) -> Data {
    let observationDigest = domainDigest(
      "levarac:observation-digest:v1",
      bytes: observationBytes
    )
    let operatorId = domainDigest(
      "levarac:operator-id:v1",
      bytes: signingPublicKey
    )
    let kid = domainDigest(
      "levarac:cose-kid:v1",
      bytes: signingPublicKey
    ).prefix(8)
    let protected = TestCbor.map([
      (TestCbor.uint(1), TestCbor.negative(-47)),
      (TestCbor.uint(3), TestCbor.text("application/vnd.levarac.acceptance-receipt+cbor")),
      (TestCbor.uint(4), TestCbor.bytes(Data(kid)))
    ])
    let payload = TestCbor.map([
      (TestCbor.uint(1), TestCbor.uint(1)),
      (TestCbor.uint(2), TestCbor.bytes(operatorId)),
      (TestCbor.uint(3), TestCbor.bytes(observationDigest)),
      (TestCbor.uint(4), TestCbor.bytes(eventId)),
      (TestCbor.uint(5), TestCbor.uint(1)),
      (TestCbor.uint(6), TestCbor.uint(2)),
      (TestCbor.uint(7), TestCbor.bytes(Data(repeating: 0, count: 32)))
    ])
    let sigStructure = TestCbor.array([
      TestCbor.text("Signature1"),
      TestCbor.bytes(protected),
      TestCbor.bytes(Data()),
      TestCbor.bytes(payload)
    ])
    let digest = Data(SHA256.hash(data: sigStructure))
    let signature = TestSecp256k1.sign(
      messageHash: digest,
      privateScalar: signingPrivateKey.last ?? 0
    )
    var compactSignature = signature.r
    compactSignature.append(signature.s)
    return TestCbor.tag(
      18,
      TestCbor.array([
        TestCbor.bytes(protected),
        TestCbor.map([]),
        TestCbor.bytes(payload),
        TestCbor.bytes(compactSignature)
      ])
    )
  }

  private func record(_ error: Error) {
    lock.lock()
    startupError = error
    lock.unlock()
  }
}

private struct HTTPRequest {
  let method: String
  let path: String
  let body: Data
}

private enum StubOperatorError: Error, CustomStringConvertible {
  case startTimedOut(diagnostics: String)
  case requestTimedOut(diagnostics: String)
  case submissionStateTimedOut(expected: String, diagnostics: String)
  case joinedStateTimedOut(expected: String, actual: String?, refusal: String)

  var description: String {
    switch self {
    case .startTimedOut(let diagnostics):
      return "stub operator did not become ready: \(diagnostics)"
    case .requestTimedOut(let diagnostics):
      return "stub operator request timeout: \(diagnostics)"
    case let .submissionStateTimedOut(expected, diagnostics):
      return "submission state timeout: expected \(expected); \(diagnostics)"
    case let .joinedStateTimedOut(expected, actual, refusal):
      return "join timeout: expected \(expected), actual \(actual ?? "nil"), refusal \(refusal)"
    }
  }
}

private enum TestCbor {
  static func uint(_ value: UInt64) -> Data {
    typeAndValue(majorType: 0, value: value)
  }

  static func negative(_ value: Int64) -> Data {
    precondition(value < 0)
    return typeAndValue(majorType: 1, value: UInt64(-1 - value))
  }

  static func bytes(_ value: Data) -> Data {
    var result = typeAndValue(majorType: 2, value: UInt64(value.count))
    result.append(value)
    return result
  }

  static func text(_ value: String) -> Data {
    bytesWithMajorType(majorType: 3, value: Data(value.utf8))
  }

  static func array(_ values: [Data]) -> Data {
    var result = typeAndValue(majorType: 4, value: UInt64(values.count))
    values.forEach { result.append($0) }
    return result
  }

  static func map(_ entries: [(Data, Data)]) -> Data {
    var result = typeAndValue(majorType: 5, value: UInt64(entries.count))
    entries.sorted { lexicographicallyLess($0.0, $1.0) }.forEach { key, value in
      result.append(key)
      result.append(value)
    }
    return result
  }

  static func tag(_ tag: UInt64, _ value: Data) -> Data {
    var result = typeAndValue(majorType: 6, value: tag)
    result.append(value)
    return result
  }

  private static func bytesWithMajorType(majorType: UInt8, value: Data) -> Data {
    var result = typeAndValue(majorType: majorType, value: UInt64(value.count))
    result.append(value)
    return result
  }

  private static func typeAndValue(majorType: UInt8, value: UInt64) -> Data {
    var result = Data()
    if value < 24 {
      result.append((majorType << 5) | UInt8(value))
    } else if value <= 0xff {
      result.append((majorType << 5) | 24)
      result.append(UInt8(value))
    } else if value <= 0xffff {
      result.append((majorType << 5) | 25)
      result.append(UInt8((value >> 8) & 0xff))
      result.append(UInt8(value & 0xff))
    } else if value <= 0xffff_ffff {
      result.append((majorType << 5) | 26)
      for shift in stride(from: 24, through: 0, by: -8) {
        result.append(UInt8((value >> UInt64(shift)) & 0xff))
      }
    } else {
      result.append((majorType << 5) | 27)
      for shift in stride(from: 56, through: 0, by: -8) {
        result.append(UInt8((value >> UInt64(shift)) & 0xff))
      }
    }
    return result
  }

  private static func lexicographicallyLess(_ left: Data, _ right: Data) -> Bool {
    for (l, r) in zip(left, right) where l != r {
      return l < r
    }
    return left.count < right.count
  }
}

@MainActor
final class ReportSubmissionOperatorIntegrationTests: XCTestCase {
  func testForegroundAndNextCaptureProbeOnceBeforeBackoffWithoutOverlappingRequests() async throws {
    let server = try StubOperatorServer(
      eventId: XCTUnwrap(Data(hexEncoded: eventIdHex)),
      signingPrivateKey: receiptPrivateKey, signingPublicKey: receiptPublicKey,
      transientPostFailures: 10
    )
    defer { server.stop() }
    let endpoint = try await server.start()
    let directory = try makeIsolatedDirectory(named: "beid-device-wide-natural-probes")
    let fileURL = directory.appendingPathComponent("report-submissions.json")
    _ = try seedPendingRecords(count: 1, endpoint: endpoint, fileURL: fileURL)
    let scheduler = ManualReportSubmissionRetryScheduler()
    let runtime = try XCTUnwrap(makeRuntime(
      endpoint: endpoint, receiptPublicKeyHex: receiptKeyHex,
      cryptography: TestSensingCryptography(), fileURL: fileURL, enabled: true,
      retryScheduler: scheduler, now: { scheduler.now }
    ))
    let coordinator = makeSubmissionCoordinator(cryptography: TestSensingCryptography(), runtime: runtime)
    runtime.submitPending()
    try await waitUntil { runtime.activeSubmissionCountForTesting == 0 && scheduler.entries.count == 1 }
    XCTAssertEqual(scheduler.now, 0)
    server.holdNewResponses()
    coordinator.retryPendingSubmissionsOnForeground()
    coordinator.retryPendingSubmissionsOnForeground()
    XCTAssertEqual(runtime.activeSubmissionCountForTesting, 1, "foreground may probe before the deadline")
    XCTAssertTrue(scheduler.entries[0].cancelled)
    try await server.waitFor(postCount: 1, getCount: 1)
    server.releaseResponses()
    try await waitUntil { runtime.activeSubmissionCountForTesting == 0 && scheduler.entries.count == 2 }
    server.holdNewResponses()
    runtime.captureAndQueueWindow(
      id: UUID(), eventCode: "device-wide-outage", eventIdHex: eventIdHex, enin: 13,
      peerRpids: ["01" + String(repeating: "bb", count: 16)],
      reporterRpid: "01" + String(repeating: "aa", count: 16), participantCommitment: nil
    )
    runtime.submitPending()
    XCTAssertEqual(runtime.activeSubmissionCountForTesting, 1, "next capture may probe the oldest record once")
    XCTAssertTrue(scheduler.entries[1].cancelled)
    // Release on the server queue before yielding to the new capture's
    // signing work; holding a real HTTP reply during that work can create
    // the client's intentional four-second transport timeout.
    server.releaseResponses()
    try await server.waitFor(postCount: 2, getCount: 2)
    try await waitUntil { runtime.activeSubmissionCountForTesting == 0 && scheduler.entries.count == 3
        && ReportSubmissionStore(fileURL: fileURL).pendingRecords.count == 2
    }
    XCTAssertEqual(server.postCount, 3)
    XCTAssertEqual(server.getCount, 2)
    XCTAssertEqual(server.maximumInFlight, 1)
    XCTAssertEqual(ReportSubmissionStore(fileURL: fileURL).pendingRecords.count, 2)
    XCTAssertEqual(scheduler.entries.last?.deadline, 8, "natural probes advance rather than reset the shared backoff")
    scheduler.now = 4
    scheduler.entries[0].action()
    scheduler.entries[1].action()
    XCTAssertEqual(runtime.activeSubmissionCountForTesting, 0, "cancelled callbacks cannot launch duplicate probes")
  }

  func testTwelvePendingRecordsDoNotMultiplyOneHourOfOutageRetries() async throws {
    let one = try await attemptsDuringOneHourOfOutage(recordCount: 1)
    let twelve = try await attemptsDuringOneHourOfOutage(recordCount: 12)
    XCTAssertEqual(one.posts, 31)
    XCTAssertEqual(one.gets, 30)
    XCTAssertEqual(twelve.posts, one.posts, "one shared retry gate must cover every pending record")
    XCTAssertEqual(twelve.gets, one.gets)
  }

  func testRecoveryDrainsTwelveRecordsOldestFirstWithOnlyOneInFlight() async throws {
    let server = try StubOperatorServer(
      eventId: XCTUnwrap(Data(hexEncoded: eventIdHex)),
      signingPrivateKey: receiptPrivateKey,
      signingPublicKey: receiptPublicKey,
      transientPostFailures: 1,
      holdResponses: true
    )
    defer { server.stop() }
    let endpoint = try await server.start()
    let directory = try makeIsolatedDirectory(named: "beid-device-wide-recovery")
    let fileURL = directory.appendingPathComponent("report-submissions.json")
    let records = try seedPendingRecords(count: 12, endpoint: endpoint, fileURL: fileURL)
    let scheduler = ManualReportSubmissionRetryScheduler()
    let runtime = try XCTUnwrap(makeRuntime(
      endpoint: endpoint, receiptPublicKeyHex: receiptKeyHex,
      cryptography: TestSensingCryptography(), fileURL: fileURL, enabled: true,
      retryScheduler: scheduler, now: { scheduler.now }
    ))
    defer { runtime.stop() }
    runtime.submitPending()
    XCTAssertEqual(runtime.activeSubmissionCountForTesting, 1)
    runtime.submitPending()
    XCTAssertEqual(runtime.activeSubmissionCountForTesting, 1, "natural calls must not open another flight")
    try await server.waitFor(postCount: 1)
    XCTAssertEqual(server.postBodies.first, Data(hexEncoded: records[0].signedObservationHex))
    server.releaseResponses()
    try await waitUntil { runtime.activeSubmissionCountForTesting == 0 && !scheduler.entries.isEmpty }
    scheduler.advance(by: 2)
    // Twelve real signature verifications drain serially; their total
    // duration is independent of the retry deadline and HTTP timeout.
    try await waitUntil(timeout: 60, diagnostics: {
      let states = ReportSubmissionStore(fileURL: fileURL).records.map { $0.submissionState.rawValue }
      return "\(server.diagnostics), states=\(states), flights=\(runtime.activeSubmissionCountForTesting)"
    }) {
      ReportSubmissionStore(fileURL: fileURL).records.allSatisfy { $0.submissionState == .accepted }
    }
    XCTAssertEqual(server.maximumInFlight, 1)
    XCTAssertEqual(server.postCount, 13)
    let expected = try ([records[0]] + records).map { try XCTUnwrap(Data(hexEncoded: $0.signedObservationHex)) }
    XCTAssertEqual(server.postBodies, expected, "the oldest failed record is retried before the serial drain")
    XCTAssertEqual(ReportSubmissionStore(fileURL: fileURL).records.count, 12)
    XCTAssertTrue(ReportSubmissionStore(fileURL: fileURL).records.allSatisfy { $0.acceptanceReceiptHex != nil })
  }

  private let eventIdHex = String(repeating: "11", count: 32)
  private let definitionDigestHex = String(repeating: "22", count: 32)
  private let receiptKeyHex = "02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"
  private let receiptPrivateKey = [UInt8](repeating: 0, count: 31) + [2]
  private let receiptPublicKey = Data([0x02] + [
    0xc6, 0x04, 0x7f, 0x94, 0x41, 0xed, 0x7d, 0x6d,
    0x30, 0x45, 0x40, 0x6e, 0x95, 0xc0, 0x7c, 0xd8,
    0x5c, 0x77, 0x8e, 0x4b, 0x8c, 0xef, 0x3c, 0xa7,
    0xab, 0xac, 0x09, 0xb9, 0x5c, 0x70, 0x9e, 0xe5
  ])

  func testRetryableFailureRetriesAutomaticallyWithReceiptLookup() async throws {
    let server = try StubOperatorServer(
      eventId: try XCTUnwrap(Data(hexEncoded: eventIdHex)),
      signingPrivateKey: receiptPrivateKey,
      signingPublicKey: receiptPublicKey,
      transientPostFailures: 1
    )
    defer { server.stop() }
    let endpoint = try await server.start()
    let directory = try makeIsolatedDirectory(named: "beid-report-submission-retry")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("report-submissions.json")
    let scheduler = ManualReportSubmissionRetryScheduler()
    let scheduled = expectation(description: "retryable HTTP 503 schedules an automatic retry")
    scheduler.onSchedule = { scheduled.fulfill() }
    let cryptography = TestSensingCryptography()
    let runtime = try XCTUnwrap(makeRuntime(
      endpoint: endpoint,
      receiptPublicKeyHex: receiptKeyHex,
      cryptography: cryptography,
      fileURL: fileURL,
      enabled: true,
      retryScheduler: scheduler,
      now: { scheduler.now }
    ))
    let coordinator = makeSubmissionCoordinator(cryptography: cryptography, runtime: runtime)
    try await driveOneRealWindow(coordinator: coordinator)
    try await server.waitFor(postCount: 1)
    await fulfillment(of: [scheduled], timeout: 5)
    scheduler.onSchedule = nil
    guard let entry = scheduler.entries.first else { return }

    XCTAssertEqual(entry.deadline, 2)
    XCTAssertEqual(ReportSubmissionStore(fileURL: fileURL).records.first?.submissionState, .submitting)
    runtime.submitPending()
    XCTAssertEqual(server.postCount, 1)
    XCTAssertEqual(server.getCount, 0)
    scheduler.advance(by: 2)
    runtime.submitPending()
    runtime.submitPending()
    entry.action()
    try await server.waitFor(postCount: 2, getCount: 1)
    try await waitForSubmissionState(.accepted, at: fileURL, server: server)
    XCTAssertEqual(server.postCount, 2, server.diagnostics)
    XCTAssertEqual(server.getCount, 1, server.diagnostics)
    XCTAssertEqual(server.postBodies[0], server.postBodies[1], "retry must reuse the exact signed bytes")
    XCTAssertTrue(scheduler.entries.allSatisfy(\.cancelled))
  }

  func testRetryableOutageBeyondSixAttemptsEventuallyStoresReceiptWithoutResigning() async throws {
    let server = try StubOperatorServer(
      eventId: try XCTUnwrap(Data(hexEncoded: eventIdHex)),
      signingPrivateKey: receiptPrivateKey,
      signingPublicKey: receiptPublicKey,
      transientPostFailures: 6
    )
    defer { server.stop() }
    let endpoint = try await server.start()
    let directory = try makeIsolatedDirectory(named: "beid-report-submission-long-outage")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("report-submissions.json")
    let scheduler = ManualReportSubmissionRetryScheduler()
    let cryptography = TestSensingCryptography()
    let runtime = try XCTUnwrap(makeRuntime(
      endpoint: endpoint,
      receiptPublicKeyHex: receiptKeyHex,
      cryptography: cryptography,
      fileURL: fileURL,
      enabled: true,
      retryScheduler: scheduler,
      now: { scheduler.now }
    ))
    defer { runtime.stop() }
    let coordinator = makeSubmissionCoordinator(cryptography: cryptography, runtime: runtime)
    for (index, delay) in [0.0, 2.0, 4.0, 8.0, 16.0, 32.0].enumerated() {
      let scheduled = expectation(description: "retry remains scheduled after failure \(index + 1)")
      scheduler.onSchedule = { scheduled.fulfill() }
      if index == 0 {
        try await driveOneRealWindow(coordinator: coordinator)
      } else {
        scheduler.advance(by: delay)
      }
      try await server.waitFor(postCount: index + 1)
      await fulfillment(of: [scheduled], timeout: 5)
    }
    scheduler.onSchedule = nil
    let pending = try XCTUnwrap(ReportSubmissionStore(fileURL: fileURL).pendingRecords.first)
    XCTAssertEqual(pending.submissionState, .submitting)
    XCTAssertNil(pending.terminalErrorCode)
    scheduler.advance(by: 64)
    try await server.waitFor(postCount: 7, getCount: 6)
    try await waitForSubmissionState(.accepted, at: fileURL, server: server)
    let accepted = try XCTUnwrap(ReportSubmissionStore(fileURL: fileURL).records.first)
    XCTAssertEqual(accepted.signedObservationHex, pending.signedObservationHex)
    XCTAssertTrue(server.postBodies.allSatisfy { $0 == server.postBodies.first })
    XCTAssertEqual(server.postCount, 7, server.diagnostics)
    XCTAssertEqual(server.getCount, 6, "every retry must look up the receipt before reposting")
    XCTAssertNotNil(accepted.acceptanceReceiptHex)
    XCTAssertTrue(scheduler.entries.allSatisfy(\.cancelled))
  }

  func testCoordinatorReleaseInvalidatesQueuedRuntimeRetryBeforeItCanSend() async throws {
    let server = try StubOperatorServer(
      eventId: try XCTUnwrap(Data(hexEncoded: eventIdHex)),
      signingPrivateKey: receiptPrivateKey,
      signingPublicKey: receiptPublicKey,
      transientPostFailures: 1
    )
    defer { server.stop() }
    let endpoint = try await server.start()
    let directory = try makeIsolatedDirectory(named: "beid-report-submission-teardown")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("report-submissions.json")
    let scheduler = ManualReportSubmissionRetryScheduler()
    let scheduled = expectation(description: "retry pending before coordinator release")
    scheduler.onSchedule = { scheduled.fulfill() }
    let cryptography = TestSensingCryptography()
    let runtime = try XCTUnwrap(makeRuntime(
      endpoint: endpoint,
      receiptPublicKeyHex: receiptKeyHex,
      cryptography: cryptography,
      fileURL: fileURL,
      enabled: true,
      retryScheduler: scheduler,
      now: { scheduler.now }
    ))
    var coordinator: SensingCoordinator? = makeSubmissionCoordinator(cryptography: cryptography, runtime: runtime)
    try await driveOneRealWindow(coordinator: XCTUnwrap(coordinator))
    try await server.waitFor(postCount: 1)
    await fulfillment(of: [scheduled], timeout: 5)
    scheduler.onSchedule = nil
    let entry = try XCTUnwrap(scheduler.entries.first)
    weak var releasedCoordinator = coordinator
    coordinator = nil
    XCTAssertNil(releasedCoordinator)
    XCTAssertTrue(entry.cancelled, "coordinator release must cancel the timer before yielding")
    scheduler.now = 2
    entry.action()
    runtime.submitPending()
    // Yield only after attempting the stale callback, so delayed cleanup
    // cannot make a racy teardown pass by running before the assertion.
    await Task.yield()
    XCTAssertEqual(server.postCount, 1, server.diagnostics)
    XCTAssertEqual(server.getCount, 0, server.diagnostics)
    XCTAssertEqual(ReportSubmissionStore(fileURL: fileURL).pendingRecords.first?.submissionState, .submitting)
  }

  func testStoppingRuntimeCancelsRetryAndPreservesThePendingCapture() async throws {
    let server = try StubOperatorServer(
      eventId: try XCTUnwrap(Data(hexEncoded: eventIdHex)),
      signingPrivateKey: receiptPrivateKey,
      signingPublicKey: receiptPublicKey,
      transientPostFailures: 1
    )
    defer { server.stop() }
    let endpoint = try await server.start()
    let directory = try makeIsolatedDirectory(named: "beid-report-submission-stop")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("report-submissions.json")
    let scheduler = ManualReportSubmissionRetryScheduler()
    let scheduled = expectation(description: "retry is pending before runtime stop")
    scheduler.onSchedule = { scheduled.fulfill() }
    let cryptography = TestSensingCryptography()
    let runtime = try XCTUnwrap(makeRuntime(
      endpoint: endpoint,
      receiptPublicKeyHex: receiptKeyHex,
      cryptography: cryptography,
      fileURL: fileURL,
      enabled: true,
      retryScheduler: scheduler,
      now: { scheduler.now }
    ))
    let coordinator = makeSubmissionCoordinator(cryptography: cryptography, runtime: runtime)
    try await driveOneRealWindow(coordinator: coordinator)
    try await server.waitFor(postCount: 1)
    await fulfillment(of: [scheduled], timeout: 5)
    scheduler.onSchedule = nil
    let entry = try XCTUnwrap(scheduler.entries.first)

    runtime.stop()
    XCTAssertTrue(entry.cancelled)
    scheduler.advance(by: 2)
    entry.action()
    runtime.submitPending()
    XCTAssertEqual(server.postCount, 1, server.diagnostics)
    XCTAssertEqual(server.getCount, 0, server.diagnostics)
    XCTAssertEqual(ReportSubmissionStore(fileURL: fileURL).pendingRecords.first?.submissionState, .submitting)
    XCTAssertNil(ReportSubmissionStore(fileURL: fileURL).records.first?.terminalErrorCode)
  }

  func testNormalRuntimeWindowCloseSubmitsAndStoresVerifiedReceipt() async throws {
    let server = try StubOperatorServer(
      eventId: try XCTUnwrap(Data(hexEncoded: eventIdHex)),
      signingPrivateKey: receiptPrivateKey,
      signingPublicKey: receiptPublicKey
    )
    defer { server.stop() }
    let endpoint = try await server.start()
    let directory = try makeIsolatedDirectory(named: "beid-report-submission-normal")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("report-submissions.json")
    let cryptography = TestSensingCryptography()
    let runtime = try XCTUnwrap(makeRuntime(
      endpoint: endpoint,
      receiptPublicKeyHex: receiptKeyHex,
      cryptography: cryptography,
      fileURL: fileURL,
      enabled: true
    ))

    let coordinator = makeSubmissionCoordinator(
      cryptography: cryptography,
      runtime: runtime
    )
    try await driveOneRealWindow(coordinator: coordinator)

    try await server.waitFor(postCount: 1)
    try await waitForSubmissionState(.accepted, at: fileURL, server: server)
    let record = try XCTUnwrap(ReportSubmissionStore(fileURL: fileURL).records.first)
    let postedBody = try XCTUnwrap(server.postBodies.first)
    XCTAssertEqual(record.submissionState, .accepted)
    XCTAssertNotNil(record.acceptanceReceiptHex)
    XCTAssertNil(record.terminalErrorCode)
    XCTAssertFalse(record.signedObservationHex.isEmpty)
    XCTAssertEqual(postedBody, try XCTUnwrap(Data(hexEncoded: record.signedObservationHex)))
  }

  func testRegistryLookupUsesTheCanonicalEventIdForTheJoinedEvent() async throws {
    let server = try StubOperatorServer(
      eventId: try XCTUnwrap(Data(hexEncoded: eventIdHex)),
      signingPrivateKey: receiptPrivateKey,
      signingPublicKey: receiptPublicKey
    )
    defer { server.stop() }
    let endpoint = try await server.start()
    let directory = try makeIsolatedDirectory(named: "beid-report-submission-canonical-id")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("report-submissions.json")
    let cryptography = TestSensingCryptography()
    let configuration = try makeConfiguration(endpoint: endpoint)
    let lookup = RecordingRegistryLookup(configuration: configuration)
    let provider = RegistryEventDefinitionContextProvider(lookup: lookup.resolve)
    let runtime = try XCTUnwrap(makeRuntime(
      endpoint: endpoint,
      receiptPublicKeyHex: receiptKeyHex,
      cryptography: cryptography,
      fileURL: fileURL,
      enabled: true,
      provider: provider
    ))
    let coordinator = makeSubmissionCoordinator(
      cryptography: cryptography,
      runtime: runtime
    )

    try await driveOneRealWindow(coordinator: coordinator, eventIdHex: eventIdHex)

    try await server.waitFor(postCount: 1)
    XCTAssertEqual(lookup.requestedEventIds, [eventIdHex])
    XCTAssertEqual(
      ReportSubmissionStore(fileURL: fileURL).records.first?.eventIdHex,
      eventIdHex
    )
  }

  func testWindowCloseCaptureSurvivesResolutionGapAndCompletesAfterRelaunch() async throws {
    let server = try StubOperatorServer(
      eventId: try XCTUnwrap(Data(hexEncoded: eventIdHex)),
      signingPrivateKey: receiptPrivateKey,
      signingPublicKey: receiptPublicKey
    )
    defer { server.stop() }
    let endpoint = try await server.start()
    let directory = try makeIsolatedDirectory(named: "beid-report-submission-capture-relaunch")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("report-submissions.json")
    let cryptography = TestSensingCryptography()
    let configuration = try makeConfiguration(endpoint: endpoint)
    let firstProvider = DeferredEventDefinitionContextProvider(configuration: configuration)
    let firstRuntime = try XCTUnwrap(makeRuntime(
      endpoint: endpoint,
      receiptPublicKeyHex: receiptKeyHex,
      cryptography: cryptography,
      fileURL: fileURL,
      enabled: true,
      provider: firstProvider
    ))
    let firstCoordinator = makeSubmissionCoordinator(
      cryptography: cryptography,
      runtime: firstRuntime
    )

    try await driveOneRealWindow(coordinator: firstCoordinator, eventIdHex: eventIdHex)

    let capture = try XCTUnwrap(ReportSubmissionStore(fileURL: fileURL).pendingCaptures.first)
    XCTAssertEqual(firstProvider.requestedEventIds, [eventIdHex])
    XCTAssertEqual(capture.eventIdHex, eventIdHex)
    XCTAssertEqual(capture.enin, 7)
    XCTAssertFalse(capture.peerRpids.isEmpty)
    XCTAssertNotNil(capture.reporterRpid)

    let relaunchedProvider = DeferredEventDefinitionContextProvider(configuration: configuration)
    let relaunchedRuntime = try XCTUnwrap(makeRuntime(
      endpoint: endpoint,
      receiptPublicKeyHex: receiptKeyHex,
      cryptography: cryptography,
      fileURL: fileURL,
      enabled: true,
      provider: relaunchedProvider
    ))
    let relaunchedCoordinator = SensingCoordinator(
      loadingFromDirectory: directory,
      sensingCryptography: cryptography,
      reportSubmissionRuntime: relaunchedRuntime
    )
    // The relaunched app's owner must remain alive until the receipt is
    // durable; releasing it intentionally cancels submission callbacks.
    defer { withExtendedLifetime(relaunchedCoordinator) {} }
    await relaunchedCoordinator.waitForLedgerLoadToFinish()

    XCTAssertEqual(relaunchedCoordinator.phase, .idle)
    XCTAssertEqual(relaunchedProvider.requestedEventIds, [eventIdHex])

    relaunchedProvider.resolveAll()
    try await server.waitFor(postCount: 1)
    try await waitForSubmissionState(.accepted, at: fileURL, server: server)
    XCTAssertTrue(ReportSubmissionStore(fileURL: fileURL).pendingCaptures.isEmpty)
  }

  func testFlagOffLeavesTheRealCoordinatorPathWithoutASubmission() async throws {
    let server = try StubOperatorServer(
      eventId: try XCTUnwrap(Data(hexEncoded: eventIdHex)),
      signingPrivateKey: receiptPrivateKey,
      signingPublicKey: receiptPublicKey
    )
    defer { server.stop() }
    let endpoint = try await server.start()
    let directory = try makeIsolatedDirectory(named: "beid-report-submission-off")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("report-submissions.json")
    let cryptography = TestSensingCryptography()
    let runtime = try makeRuntime(
      endpoint: endpoint,
      receiptPublicKeyHex: receiptKeyHex,
      cryptography: cryptography,
      fileURL: fileURL,
      enabled: false
    )
    XCTAssertNil(runtime)

    let coordinator = makeSubmissionCoordinator(
      cryptography: cryptography,
      runtime: runtime
    )
    try await driveOneRealWindow(coordinator: coordinator)
    try await Task.sleep(nanoseconds: 100_000_000)

    XCTAssertEqual(server.postCount, 0)
    XCTAssertEqual(server.getCount, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
  }

  func testEnabledButUnconfiguredRuntimeDoesNotCreateOrTouchTheQueue() throws {
    let directory = try makeIsolatedDirectory(named: "beid-report-submission-unconfigured")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("report-submissions.json")

    let runtime = try makeRuntime(
      endpoint: try XCTUnwrap(URL(string: "http://127.0.0.1:8080")),
      receiptPublicKeyHex: receiptKeyHex,
      cryptography: TestSensingCryptography(),
      fileURL: fileURL,
      enabled: true,
      useDefaultProvider: false
    )

    XCTAssertNil(runtime)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
  }

  #if DEBUG
  func testCrashAfterAcceptBeforeStoreLooksUpBeforePostingAgain() async throws {
    let server = try StubOperatorServer(
      eventId: try XCTUnwrap(Data(hexEncoded: eventIdHex)),
      signingPrivateKey: receiptPrivateKey,
      signingPublicKey: receiptPublicKey
    )
    defer { server.stop() }
    let endpoint = try await server.start()
    let directory = try makeIsolatedDirectory(named: "beid-report-submission-crash")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("report-submissions.json")
    let cryptography = TestSensingCryptography()
    let firstRuntime = try XCTUnwrap(makeRuntime(
      endpoint: endpoint,
      receiptPublicKeyHex: receiptKeyHex,
      cryptography: cryptography,
      fileURL: fileURL,
      enabled: true
    ))
    firstRuntime.receiptPersistenceGate = { false }

    let firstCoordinator = makeSubmissionCoordinator(
      cryptography: cryptography,
      runtime: firstRuntime
    )
    try await driveOneRealWindow(coordinator: firstCoordinator)
    try await server.waitFor(postCount: 1)

    // Quiesce the first process at the crash boundary before opening a
    // second store/client over the same durable queue.
    try await waitUntil { firstRuntime.activeSubmissionCountForTesting == 0 }
    firstRuntime.stop()
    let crashedRecord = try XCTUnwrap(ReportSubmissionStore(fileURL: fileURL).records.first)
    let postedBody = try XCTUnwrap(server.postBodies.first)
    XCTAssertEqual(crashedRecord.submissionState, .submitting)
    XCTAssertNil(crashedRecord.acceptanceReceiptHex)
    XCTAssertEqual(postedBody, try XCTUnwrap(Data(hexEncoded: crashedRecord.signedObservationHex)))

    let relaunchedRuntime = try XCTUnwrap(makeRuntime(
      endpoint: endpoint,
      receiptPublicKeyHex: receiptKeyHex,
      cryptography: cryptography,
      fileURL: fileURL,
      enabled: true
    ))
    let relaunchedCoordinator = SensingCoordinator(
      loadingFromDirectory: directory,
      sensingCryptography: cryptography,
      reportSubmissionRuntime: relaunchedRuntime
    )
    await relaunchedCoordinator.waitForLedgerLoadToFinish()

    XCTAssertEqual(relaunchedCoordinator.phase, .idle)
    try await server.waitFor(postCount: 1, getCount: 1)
    try await waitForSubmissionState(.accepted, at: fileURL, server: server)
    let restored = try XCTUnwrap(ReportSubmissionStore(fileURL: fileURL).records.first)
    XCTAssertEqual(restored.submissionState, .accepted)
    XCTAssertNotNil(restored.acceptanceReceiptHex)
    XCTAssertEqual(server.postCount, 1, "relaunch lookup must prevent a duplicate POST")
  }
  #endif

  func testReceiptSignedByKeyOutsideVerifiedDefinitionIsRejected() async throws {
    let wrongPrivateKey = [UInt8](repeating: 0, count: 31) + [3]
    let wrongPublicKey = Data([
      0x02, 0xf9, 0x30, 0x8a, 0x01, 0x92, 0x58, 0xc3, 0x10, 0x49, 0x34,
      0x4f, 0x85, 0xf8, 0x9d, 0x52, 0x29, 0xb5, 0x31, 0xc8, 0x45, 0x83,
      0x6f, 0x99, 0xb0, 0x86, 0x01, 0xf1, 0x13, 0xbc, 0xe0, 0x36, 0xf9
    ])
    let server = try StubOperatorServer(
      eventId: try XCTUnwrap(Data(hexEncoded: eventIdHex)),
      signingPrivateKey: wrongPrivateKey,
      signingPublicKey: wrongPublicKey
    )
    defer { server.stop() }
    let endpoint = try await server.start()
    let directory = try makeIsolatedDirectory(named: "beid-report-submission-wrong-key")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("report-submissions.json")
    let cryptography = TestSensingCryptography()
    let runtime = try XCTUnwrap(makeRuntime(
      endpoint: endpoint,
      receiptPublicKeyHex: receiptKeyHex,
      cryptography: cryptography,
      fileURL: fileURL,
      enabled: true
    ))

    let coordinator = makeSubmissionCoordinator(
      cryptography: cryptography,
      runtime: runtime
    )
    try await driveOneRealWindow(coordinator: coordinator)
    try await server.waitFor(postCount: 1)
    try await waitForTerminalFailure(at: fileURL, server: server)

    let record = try XCTUnwrap(ReportSubmissionStore(fileURL: fileURL).records.first)
    XCTAssertNil(record.acceptanceReceiptHex)
    XCTAssertEqual(record.terminalErrorCode, "protocol_error")
    XCTAssertNotEqual(record.submissionState, .accepted)
  }

  func testRealSignedWindowGetsVerifiedReceiptFromReferenceOperator() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["BEID_RUN_OPERATOR_SUBMISSION_TEST"] == "1" else {
      throw XCTSkip("set BEID_RUN_OPERATOR_SUBMISSION_TEST=1 to run the local operator integration")
    }

    let endpoint = try requiredEnvironment("BEID_OPERATOR_SUBMISSION_ENDPOINT", from: environment)
    let receiptPublicKey = try requiredEnvironment("BEID_OPERATOR_RECEIPT_PUBLIC_KEY", from: environment)
    let eventId = try requiredEnvironment("BEID_EVENT_ID", from: environment)
    let definitionDigest = try requiredEnvironment("BEID_EVENT_DEFINITION_DIGEST", from: environment)
    let configuration = try XCTUnwrap(
      ExportedKotlinPackages.org.levarac.parallax.submission
        .createSubmissionOperatorConfiguration(
          endpoint: endpoint,
          receiptPublicKeyHex: receiptPublicKey,
          eventIdHex: eventId,
          eventDefinitionDigestHex: definitionDigest,
          validFrom: nil,
          validUntil: nil,
          allowInsecureLoopbackForTests: true
        )
    )

    let eventCode = "operator-integration-\(UUID().uuidString)"
    let cryptography = BarnardSensingCryptography()
    let reporterRpid = "01" + String(repeating: "aa", count: 16)
    let observedRpid = "01" + String(repeating: "bb", count: 16)
    let evidence = try XCTUnwrap(
      ExportedKotlinPackages.org.levarac.parallax.observation
        .createMutualSensingWindowEvidence(
          idHex: UUID().hexString,
          eventIdHex: eventId,
          eventDefinitionDigestHex: definitionDigest,
          observerHex: cryptography.eventSigningPublicKey(eventCode: eventCode).hexString,
          finalizedAt: Date().timeIntervalSince1970,
          reporterRpidHex: reporterRpid,
          enin: 1,
          observedRpidHexes: [observedRpid],
          rpidClaimHex: nil,
          participantCommitmentHex: nil,
          legacyPeerCount: nil
        )
    )
    let preparation = ExportedKotlinPackages.org.levarac.parallax.observation
      .prepareMutualSensingObservation(evidence: evidence)
    let eligible = try XCTUnwrap(
      preparation as?
        ExportedKotlinPackages.org.levarac.parallax.observation.ObservationPreparationResult.Eligible
    )
    let signature = cryptography.signWindowReport(
      eventCode: eventCode,
      bytes: Data(bytesFromKotlinByteArray: eligible.prepared.signatureStructure.toByteArray())
    )
    let signed = eligible.prepared.signWithCompactSignatureHex(
      rHex: signature.r.hexString,
      sHex: signature.s.hexString
    )
    let stored = ExportedKotlinPackages.org.levarac.parallax.submission
      .storeSignedObservation(signed: signed)
    let client = ExportedKotlinPackages.org.levarac.parallax.submission.createSubmissionClient()
    defer { client.close() }

    let result = await withCheckedContinuation {
      (continuation: CheckedContinuation<ExportedKotlinPackages.org.levarac.parallax.submission.SubmissionResult, Never>) in
      client.submit(observation: stored, configuration: configuration) { result in
        continuation.resume(returning: result)
      }
    }

    XCTAssertTrue(result.isSuccess, result.errorMessage ?? "reference operator did not accept the Observation")
    XCTAssertNotNil(result.receipt)
    XCTAssertEqual(result.statusCode, 201, "the test submits a fresh Observation, not an idempotent retry")
  }

  private func makeRuntime(
    endpoint: URL,
    receiptPublicKeyHex: String,
    cryptography: any SensingCryptography,
    fileURL: URL,
    enabled: Bool,
    provider: (any EventDefinitionContextProvider)? = nil,
    useDefaultProvider: Bool = true,
    retryScheduler: (any ReportSubmissionRetryScheduler)? = nil,
    now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    retryJitter: @escaping () -> Double = { 1 }
  ) throws -> ReportSubmissionRuntime? {
    let configuration = try XCTUnwrap(
      ExportedKotlinPackages.org.levarac.parallax.submission
        .createSubmissionOperatorConfiguration(
          endpoint: endpoint.absoluteString,
          receiptPublicKeyHex: receiptPublicKeyHex,
          eventIdHex: eventIdHex,
          eventDefinitionDigestHex: definitionDigestHex,
          validFrom: nil,
          validUntil: nil,
          allowInsecureLoopbackForTests: true
        ),
      "endpoint=\(endpoint.absoluteString)"
    )
    let resolvedProvider: (any EventDefinitionContextProvider)?
    if let provider {
      resolvedProvider = provider
    } else if useDefaultProvider {
      resolvedProvider = StaticEventDefinitionContextProvider(configuration: configuration)
    } else {
      resolvedProvider = nil
    }
    let bundleDirectory = try makeIsolatedDirectory(named: "beid-report-submission-bundle")
    let plist: [String: Any] = [
      "CFBundleIdentifier": "org.levarac.beid.tests.\(UUID().uuidString)",
      "CFBundlePackageType": "BNDL",
      "BeidReportSubmissionEnabled": enabled ? "1" : "0"
    ]
    let plistData = try PropertyListSerialization.data(
      fromPropertyList: plist,
      format: .xml,
      options: 0
    )
    try plistData.write(to: bundleDirectory.appendingPathComponent("Info.plist"))
    let bundle = try XCTUnwrap(Bundle(url: bundleDirectory))
    return ReportSubmissionRuntime.makeIfEnabled(
      bundle: bundle,
      eventSigningCryptography: cryptography,
      definitionProvider: resolvedProvider,
      fileURL: fileURL,
      retryScheduler: retryScheduler,
      now: now,
      retryJitter: retryJitter,
      allowInsecureLoopbackForTests: true
    )
  }

  private func driveOneRealWindow(
    coordinator: SensingCoordinator,
    eventIdHex: String? = nil
  ) async throws {
    coordinator.useDemoEventMode = false
    let joinedForTest = eventIdHex != nil
    defer {
      if joinedForTest {
        coordinator.leaveEvent()
      }
    }
    if let eventIdHex {
      XCTAssertTrue(
        coordinator.joinEvent(
          "verified-definition-event",
          canonicalEventIdHex: eventIdHex
        )
      )
      coordinator.startSensing()
    } else {
      coordinator.startSensing(
        eventCode: "verified-definition-event",
        eventIdHex: self.eventIdHex
      )
    }
    let expectedEventId = eventIdHex ?? self.eventIdHex
    for _ in 0..<1_000 {
      if coordinator.relayGateJoinedEventIdHexForTesting == expectedEventId { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    guard coordinator.relayGateJoinedEventIdHexForTesting == expectedEventId else {
      throw StubOperatorError.joinedStateTimedOut(
        expected: expectedEventId,
        actual: coordinator.relayGateJoinedEventIdHexForTesting,
        refusal: String(describing: coordinator.joinRefusal)
      )
    }
    let reporterRpid = "01" + String(repeating: "aa", count: 16)
    for index in 0..<BeidConfig.eventConfirmThreshold {
      let rpid = "01" + String(format: "%032x", index + 1)
      coordinator.handleDetection(
        enin: 7,
        rpid: rpid,
        detectedDisplayId: DetectionFixture.displayId(device: index),
        reporterRpid: reporterRpid
      )
    }
    _ = coordinator.stopSensing()
  }

  /// A coordinator whose join gate can actually admit.
  ///
  /// These tests drive `handleDetection` directly, so what they need from
  /// `startSensing` is a real session — not the Simulator's answer about a
  /// radio it does not have. Until beid#473 they got one **by accident**: the
  /// Simulator refuses the permission grant, and `startSensing` left its
  /// optimistic `.sensing` phase in place anyway, so the session existed
  /// because of a defect. Fixing that defect broke all five of these tests at
  /// once, which is how the dependency was found — they had been exercising
  /// the submission pipeline from a state the app could not legitimately
  /// reach on that platform.
  ///
  /// Now the grant is granted and the registry admits, both explicitly, so
  /// the session these tests run in is one the gate actually allowed.
  @MainActor
  private func makeSubmissionCoordinator(
    cryptography: any SensingCryptography,
    runtime: (any WindowReportSubmissionRuntimeProtocol)?
  ) -> SensingCoordinator {
    let engine = RecordingEventJoinControl()
    engine.permissionOutcome = .granted
    let registry = FakeEventJoinRegistry()
    registry.answer = .resolves(
      FakeEventJoinRegistry.admittingResolution(eventIdHex: eventIdHex)
    )
    return makeIsolatedSensingCoordinator(
      for: self,
      sensingCryptography: cryptography,
      reportSubmissionRuntime: runtime,
      eventJoinControl: engine,
      eventJoinRegistry: registry
    )
  }

  private func makeConfiguration(
    endpoint: URL
  ) throws -> ExportedKotlinPackages.org.levarac.parallax.submission
    .SubmissionOperatorConfiguration {
    try XCTUnwrap(
      ExportedKotlinPackages.org.levarac.parallax.submission
        .createSubmissionOperatorConfiguration(
          endpoint: endpoint.absoluteString,
          receiptPublicKeyHex: receiptKeyHex,
          eventIdHex: eventIdHex,
          eventDefinitionDigestHex: definitionDigestHex,
          validFrom: nil,
          validUntil: nil,
          allowInsecureLoopbackForTests: true
        )
    )
  }

  private func attemptsDuringOneHourOfOutage(recordCount: Int) async throws -> (posts: Int, gets: Int) {
    let server = try StubOperatorServer(
      eventId: XCTUnwrap(Data(hexEncoded: eventIdHex)),
      signingPrivateKey: receiptPrivateKey, signingPublicKey: receiptPublicKey,
      transientPostFailures: 10_000
    )
    defer { server.stop() }
    let endpoint = try await server.start()
    let directory = try makeIsolatedDirectory(named: "beid-device-wide-outage")
    let fileURL = directory.appendingPathComponent("report-submissions.json")
    _ = try seedPendingRecords(count: recordCount, endpoint: endpoint, fileURL: fileURL)
    let scheduler = ManualReportSubmissionRetryScheduler()
    let runtime = try XCTUnwrap(makeRuntime(
      endpoint: endpoint, receiptPublicKeyHex: receiptKeyHex,
      cryptography: TestSensingCryptography(), fileURL: fileURL, enabled: true,
      retryScheduler: scheduler, now: { scheduler.now }, retryJitter: { 0 }
    ))
    defer { runtime.stop() }
    runtime.submitPending()
    try await waitUntil { runtime.activeSubmissionCountForTesting == 0 && !scheduler.entries.isEmpty }
    while let next = scheduler.entries.filter({ !$0.cancelled }).map(\.deadline).min(), next <= 3_600 {
      let scheduledCount = scheduler.entries.count
      scheduler.advance(by: next - scheduler.now)
      try await waitUntil {
        runtime.activeSubmissionCountForTesting == 0 && scheduler.entries.count > scheduledCount
      }
    }
    XCTAssertEqual(ReportSubmissionStore(fileURL: fileURL).pendingRecords.count, recordCount)
    return (server.postCount, server.getCount)
  }

  private func seedPendingRecords(count: Int, endpoint: URL, fileURL: URL) throws -> [ReportSubmissionRecord] {
    let cryptography = TestSensingCryptography()
    let configuration = try makeConfiguration(endpoint: endpoint)
    let records = try (0..<count).map { index in
      let id = UUID()
      let eventCode = "device-wide-outage"
      let evidence = try XCTUnwrap(
        ExportedKotlinPackages.org.levarac.parallax.observation.createMutualSensingWindowEvidence(
          idHex: id.hexString, eventIdHex: eventIdHex, eventDefinitionDigestHex: definitionDigestHex,
          observerHex: cryptography.eventSigningPublicKey(eventCode: eventCode).hexString,
          finalizedAt: 1_791_324_000 + Double(index),
          reporterRpidHex: "01" + String(repeating: "aa", count: 16),
          enin: Int64(index + 1), observedRpidHexes: ["01" + String(repeating: "bb", count: 16)],
          rpidClaimHex: nil, participantCommitmentHex: nil, legacyPeerCount: nil
        )
      )
      let eligible = try XCTUnwrap(
        ExportedKotlinPackages.org.levarac.parallax.observation.prepareMutualSensingObservation(evidence: evidence)
          as? ExportedKotlinPackages.org.levarac.parallax.observation.ObservationPreparationResult.Eligible
      )
      let signature = cryptography.signWindowReport(
        eventCode: eventCode,
        bytes: Data(bytesFromKotlinByteArray: eligible.prepared.signatureStructure.toByteArray())
      )
      let stored = ExportedKotlinPackages.org.levarac.parallax.submission.storeSignedObservation(
        signed: eligible.prepared.signWithCompactSignatureHex(rHex: signature.r.hexString, sHex: signature.s.hexString)
      )
      return ReportSubmissionRecord(
        id: id, eventCode: eventCode, endpoint: endpoint.absoluteString, receiptPublicKeyHex: receiptKeyHex,
        eventIdHex: eventIdHex, eventDefinitionDigestHex: definitionDigestHex, validFrom: nil, validUntil: nil,
        signedObservationHex: Data(bytesFromKotlinByteArray: stored.signedBytes.toByteArray()).hexString,
        observationDigestHex: Data(bytesFromKotlinByteArray: stored.observationDigest.toByteArray()).hexString,
        operatorIdHex: Data(bytesFromKotlinByteArray: configuration.operatorId.toByteArray()).hexString,
        createdAt: Date(timeIntervalSince1970: 1_791_324_000 + Double(index))
      )
    }
    let store = ReportSubmissionStore(fileURL: fileURL)
    // Durable storage order can differ from creation order after resolution.
    for record in records.reversed() { try store.add(record) }
    return records
  }

  private func waitUntil(
    timeout: TimeInterval = 10,
    diagnostics: () -> String = { "condition timed out" },
    _ predicate: () -> Bool
  ) async throws {
    for _ in 0..<Int(timeout / 0.01) {
      if predicate() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("runtime did not reach the expected durable/idle state: \(diagnostics())")
    throw StubOperatorError.submissionStateTimedOut(expected: "durable/idle", diagnostics: diagnostics())
  }

  private func waitForSubmissionState(
    _ expected: ReportSubmissionState,
    at fileURL: URL,
    server: StubOperatorServer
  ) async throws {
    // Receipt verification uses real KMP cryptography after HTTP completes.
    // Hosted runners may finish that computation after ten seconds.
    for _ in 0..<3_000 {
      if ReportSubmissionStore(fileURL: fileURL).records.first?.submissionState == expected {
        return
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw StubOperatorError.submissionStateTimedOut(expected: expected.rawValue, diagnostics: server.diagnostics)
  }

  private func waitForTerminalFailure(at fileURL: URL, server: StubOperatorServer) async throws {
    for _ in 0..<1_000 {
      if ReportSubmissionStore(fileURL: fileURL).records.first?.terminalErrorCode != nil {
        return
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw StubOperatorError.submissionStateTimedOut(expected: "terminal failure", diagnostics: server.diagnostics)
  }

  private func requiredEnvironment(
    _ name: String,
    from environment: [String: String]
  ) throws -> String {
    guard let value = environment[name], !value.isEmpty else {
      throw XCTSkip("set \(name) for the local operator integration")
    }
    return value
  }

  private func makeIsolatedDirectory(named name: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: directory)
    }
    return directory
  }
}

private func domainDigest(_ domain: String, bytes: Data) -> Data {
  var input = Data(domain.utf8)
  input.append(0)
  input.append(bytes)
  return Data(SHA256.hash(data: input))
}

private extension Data {
  init(bytesFromKotlinByteArray bytes: ExportedKotlinPackages.kotlin.ByteArray) {
    self.init((0..<Int(bytes.size)).map { index in
      UInt8(bitPattern: bytes[Int32(index)])
    })
  }

  init?(hexEncoded value: String) {
    let source = value.removingPrefix("0x")
    guard source.count.isMultiple(of: 2) else { return nil }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(source.count / 2)
    var index = source.startIndex
    while index < source.endIndex {
      let next = source.index(index, offsetBy: 2)
      guard let byte = UInt8(source[index..<next], radix: 16) else { return nil }
      bytes.append(byte)
      index = next
    }
    self.init(bytes)
  }

  var hexString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}

private extension String {
  func removingPrefix(_ prefix: String) -> String {
    hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
  }
}

private extension UUID {
  var hexString: String {
    var copy = self
    return withUnsafeBytes(of: &copy) { Data($0).hexString }
  }
}
