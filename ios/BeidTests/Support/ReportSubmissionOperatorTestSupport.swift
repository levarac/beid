// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BeidSharedKit
import CryptoKit
import Foundation
import Network
import XCTest
@testable import Beid

// Moved out of `ReportSubmissionOperatorIntegrationTests.swift` unchanged,
// apart from dropping `private`, so the beid#701 byte-identity and
// containment tests drive the same operator, signer and definition provider
// as the integration suite rather than a copy of them. `StubOperatorServer`
// additionally records the path of every GET it serves.

@MainActor
final class StaticEventDefinitionContextProvider: EventDefinitionContextProvider {
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

final class TestSensingCryptography: SensingCryptography {
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
enum TestSecp256k1 {
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
final class StubOperatorServer {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "beid.tests.stub-operator")
  private let lock = NSLock()
  private let eventId: Data
  private let signingPrivateKey: [UInt8]
  private let signingPublicKey: Data
  private var receipt: Data?
  private var startupError: Error?
  private var isReady = false
  private var isCancelled = false
  private var isStopped = false
  private var connections: [ObjectIdentifier: NWConnection] = [:]
  private var connectionCount = 0
  private var receivedByteCount = 0
  private var requestCount = 0
  private let transientPostFailures: Int
  private let terminalPostFailures: Int
  private let terminalStatus: Int
  private var _postCount = 0
  private var _getCount = 0
  private var _postBodies: [Data] = []
  private var _requestPaths: [String] = []
  private var holdResponses: Bool
  private var heldResponses: [(NWConnection, Data)] = []
  private var activeRequests = 0
  private var maximumActiveRequests = 0
  private let observationStart = ProcessInfo.processInfo.systemUptime
  private var returnedURL: URL?
  private var readyUptime: TimeInterval?
  private var readyDate: Date?
  private var readyPort: UInt16?
  private var readyEndpoint: String?
  private var clientSubscription: ExportedKotlinPackages.org.levarac.parallax.submission
    .IosSubmissionTransportTestSubscription?
  private var clientAttemptCount = 0
  private var expectedAttemptCount = 0
  private var firstClientAttempt: ClientEvent?
  private var firstExpectedAttempt: ClientEvent?
  private var lastExpectedEvent: ClientEvent?
  private var clientEvents: [ClientEvent] = []

  private struct ClientEvent {
    let id: Int64
    let phase: String
    let method: String
    let url: String
    let uptime: TimeInterval
    let httpStatus: Int32
    let errorDomain: String
    let errorCode: Int64

    func summary(since start: TimeInterval) -> String {
      let outcome: String
      if !errorDomain.isEmpty {
        outcome = "outcome=error error=\(errorDomain)/\(errorCode) HTTP=\(httpStatus)"
      } else if httpStatus != 0 {
        outcome = "outcome=response HTTP=\(httpStatus)"
      } else {
        outcome = "outcome=\(phase == "attempt" ? "pending" : phase)"
      }
      return "id=\(id) \(method) url=\(url) at+\(String(format: "%.3f", uptime - start))s phase=\(phase) \(outcome)"
    }
  }

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

  /// The request target of every request served, GETs included, in order.
  var requestPaths: [String] {
    lock.lock()
    defer { lock.unlock() }
    return _requestPaths
  }

  var diagnostics: String {
    diagnosticSnapshot(atTimeout: false)
  }

  var timeoutDiagnostics: String { diagnosticSnapshot(atTimeout: true) }

  private func diagnosticSnapshot(atTimeout: Bool) -> String {
    lock.withLock {
      let now = ProcessInfo.processInfo.systemUptime
      let classification: String
      if clientAttemptCount > 0 && expectedAttemptCount == 0 {
        classification = "attempted-different-url"
      } else if connectionCount > 0 {
        classification = "connected-but-slow"
      } else if expectedAttemptCount > 0 {
        classification = lastExpectedEvent?.errorDomain.isEmpty == false
          ? "attempted-right-url-failed" : "attempted-right-url-no-connection-yet"
      } else {
        classification = "never-attempted"
      }
      let elapsed: (TimeInterval?) -> String = { value in
        value.map { "+\(String(format: "%.3f", $0 - self.observationStart))s" } ?? "never"
      }
      let readyAt = readyDate.map { ISO8601DateFormatter().string(from: $0) } ?? "never"
      let events = clientEvents.map { $0.summary(since: observationStart) }.joined(separator: "; ")
      // NWListener exposes parameters and port, not a separate getsockname
      // endpoint. Preserve exactly what it reports; nil is not proof of IPv6
      // or IPv4 binding, and the returned URL is not the bound endpoint.
      let endpoint = listener.parameters.requiredLocalEndpoint.map { String(describing: $0) } ?? "not-reported"
      return "case=\(classification); " +
        "listenerURL=\(returnedURL?.absoluteString ?? "not-returned"), " +
        "listenerEndpoint=\(endpoint), listenerPort=\(listener.port.map { String($0.rawValue) } ?? "not-reported"), " +
        "readyEndpoint=\(readyEndpoint ?? "not-reported"), readyPort=\(readyPort.map(String.init) ?? "not-reported"), " +
        "readyAt=\(readyAt), listenerState=\(listener.state), listenerDebug=\(listener.debugDescription); " +
        "connections=\(connectionCount), bytes=\(receivedByteCount), requests=\(requestCount), POST=\(_postCount), GET=\(_getCount); " +
        "clientScope=process-during-stub-lifetime, clientAttempts=\(clientAttemptCount), expectedURLAttempts=\(expectedAttemptCount), " +
        "firstAttemptURL=\(firstClientAttempt?.url ?? "none"), " +
        "lastExpected={\(lastExpectedEvent?.summary(since: observationStart) ?? "none")}, clientEvents(last8)=[\(events)]; " +
        "timeline=[ready@\(elapsed(readyUptime)), firstAttempt=\(firstClientAttempt == nil ? "never" : elapsed(firstClientAttempt?.uptime)), " +
        "firstExpectedAttempt=\(elapsed(firstExpectedAttempt?.uptime)), \(atTimeout ? "timeout" : "sample")@\(elapsed(now))]"
    }
  }

  private func recordClientEvent(
    _ event: ExportedKotlinPackages.org.levarac.parallax.submission.IosSubmissionTransportTestEvent
  ) {
    let sample = ClientEvent(
      id: event.requestId, phase: event.phase, method: event.method, url: event.url,
      uptime: event.uptimeSeconds, httpStatus: event.httpStatus,
      errorDomain: event.errorDomain, errorCode: event.errorCode
    )
    lock.withLock {
      let expected = returnedURL.map { $0.absoluteString + "/v1/observations" }
      let matches = expected.map { sample.url == $0 ||
        (sample.url.hasPrefix($0 + "/") && sample.url.hasSuffix("/acceptance")) } ?? false
      if sample.phase == "attempt" {
        clientAttemptCount += 1
        if firstClientAttempt == nil { firstClientAttempt = sample }
        if matches {
          expectedAttemptCount += 1
          if firstExpectedAttempt == nil { firstExpectedAttempt = sample }
        }
      }
      if matches { lastExpectedEvent = sample }
      clientEvents.append(sample)
      if clientEvents.count > 8 { clientEvents.removeFirst(clientEvents.count - 8) }
    }
  }

  deinit { clientSubscription?.close() }

  init(
    eventId: Data,
    signingPrivateKey: [UInt8],
    signingPublicKey: Data,
    transientPostFailures: Int = 0,
    holdResponses: Bool = false,
    terminalPostFailures: Int = 0,
    terminalStatus: Int = 422,
    port: NWEndpoint.Port = .any
  ) throws {
    self.eventId = eventId
    self.signingPrivateKey = signingPrivateKey
    self.signingPublicKey = signingPublicKey
    self.transientPostFailures = transientPostFailures
    self.terminalPostFailures = terminalPostFailures
    self.terminalStatus = terminalStatus
    self.holdResponses = holdResponses
    listener = try NWListener(using: .tcp, on: port)
  }

  func start(timeout: TimeInterval? = nil) async throws -> URL {
    clientSubscription = ExportedKotlinPackages.org.levarac.parallax.submission
      .observeIosSubmissionTransportForTesting { [weak self] in self?.recordClientEvent($0) }
    listener.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      self.lock.lock()
      defer { self.lock.unlock() }
      if case .ready = state {
        self.isReady = true
        if self.readyUptime == nil {
          self.readyUptime = ProcessInfo.processInfo.systemUptime
          self.readyDate = Date()
          self.readyPort = self.listener.port?.rawValue
          self.readyEndpoint = self.listener.parameters.requiredLocalEndpoint.map { String(describing: $0) }
        }
      }
      if case .failed(let error) = state {
        self.startupError = error
      }
      if case .cancelled = state { self.isCancelled = true }
    }
    listener.newConnectionHandler = { [weak self] connection in
      self?.accept(connection)
    }
    listener.start(queue: queue)

    if let timeout {
      let ready = try await SubmissionTestWait.until(timeout: timeout) {
        let status = self.lock.withLock { (self.isReady, self.startupError) }
        if let error = status.1 { throw error }
        return status.0 && self.listener.port.map { $0.rawValue != 0 } == true
      }
      guard ready, let port = listener.port else {
        throw StubOperatorError.startTimedOut(diagnostics: "after \(timeout)s; \(diagnostics)")
      }
      let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port.rawValue)"))
      lock.withLock { returnedURL = url }
      return url
    }

    for _ in 0..<100 {
      let status = lock.withLock { (isReady, startupError) }
      if let error = status.1 {
        throw error
      }
      if status.0, let port = listener.port, port.rawValue != 0 {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port.rawValue)"))
        lock.withLock { returnedURL = url }
        return url
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

  func stopAndWait() async throws {
    stop()
    for _ in 0..<100 {
      if lock.withLock({ isCancelled }) { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw StubOperatorError.requestTimedOut(diagnostics: "listener did not release its port; \(timeoutDiagnostics)")
  }

  func waitFor(
    postCount expectedPosts: Int,
    getCount expectedGets: Int? = nil,
    timeout: TimeInterval? = nil
  ) async throws {
    if let timeout {
      if try await SubmissionTestWait.until(timeout: timeout, {
        self.postCount >= expectedPosts && (expectedGets.map { self.getCount >= $0 } ?? true)
      }) { return }
      let progress = lock.withLock {
        connectionCount == 0 ? "no connection arrived" : "connection arrived but expected requests did not complete"
      }
      throw StubOperatorError.requestTimedOut(
        diagnostics: "after \(timeout)s: \(progress); expected POST>=\(expectedPosts), " +
          "GET>=\(expectedGets ?? 0); \(timeoutDiagnostics)"
      )
    }

    for _ in 0..<1_000 {
      if postCount >= expectedPosts,
         expectedGets.map({ getCount >= $0 }) ?? true {
        return
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw StubOperatorError.requestTimedOut(diagnostics: timeoutDiagnostics)
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
    lock.lock()
    _requestPaths.append(request.path)
    lock.unlock()
    if request.method == "POST", request.path == "/v1/observations" {
      lock.lock()
      _postCount += 1
      _postBodies.append(request.body)
      let shouldFail = _postCount <= transientPostFailures
      let shouldReject = _postCount <= terminalPostFailures
      lock.unlock()
      if shouldReject {
        response = (terminalStatus, Data(), nil)
      } else if shouldFail {
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

@MainActor
func waitForStoredSubmissionState(
  _ expected: ReportSubmissionState,
  at fileURL: URL,
  server: StubOperatorServer
) async throws {
  var lastState: String?
  if try await SubmissionTestWait.until({
    let state = ReportSubmissionStore(fileURL: fileURL).records.first?.submissionState
    lastState = state?.rawValue
    return state == expected
  }) { return }
  throw StubOperatorError.submissionStateTimedOut(
    expected: expected.rawValue,
    diagnostics: "after \(SubmissionTestWait.timeout)s; last state \(lastState ?? "no record"); \(server.timeoutDiagnostics)"
  )
}

@MainActor
func waitForSubmissionJoin(_ coordinator: SensingCoordinator, eventIdHex: String) async throws {
  if try await SubmissionTestWait.until({
    coordinator.relayGateJoinedEventIdHexForTesting == eventIdHex
  }) { return }
  throw StubOperatorError.joinedStateTimedOut(
    expected: eventIdHex,
    actual: coordinator.relayGateJoinedEventIdHexForTesting,
    refusal: "after \(SubmissionTestWait.timeout)s; \(String(describing: coordinator.joinRefusal))"
  )
}

struct HTTPRequest {
  let method: String
  let path: String
  let body: Data
}

enum StubOperatorError: Error, CustomStringConvertible {
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

enum TestCbor {
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

func domainDigest(_ domain: String, bytes: Data) -> Data {
  var input = Data(domain.utf8)
  input.append(0)
  input.append(bytes)
  return Data(SHA256.hash(data: input))
}
