// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Combine
import Foundation

@MainActor
final class DiagnosticsController: ObservableObject {
  typealias Upload = @MainActor (Data) async throws -> Int

  @Published private(set) var isEnabled: Bool
  private let queue: DiagnosticsQueue
  private let upload: Upload?
  private var cadence: Task<Void, Never>?
  private var request: Task<Void, Never>?
  private var requestID: UUID?
  private var retryCount = 0
  private var retryAfter: TimeInterval = 0
  private var isForeground = false
  private var radarAliases: [String: (alias: DiagnosticsAlias, lastSeen: Int64)] = [:]

  init(queue: DiagnosticsQueue, upload: Upload?) {
    self.queue = queue
    self.upload = upload
    isEnabled = queue.isEnabled
  }

  var canUpload: Bool { upload != nil }
  var consentGeneration: UUID? { queue.generation }

  func enable(code: String) throws {
    guard !isEnabled else { return }
    do {
      try queue.enable(code: code)
    } catch {
      isEnabled = queue.isEnabled
      throw error
    }
    isEnabled = true
    startCadence()
  }

  func revoke() throws {
    isEnabled = false
    cadence?.cancel()
    cadence = nil
    cancelUpload()
    retryCount = 0
    retryAfter = 0
    radarAliases.removeAll()
    try queue.revoke()
  }

  func record(_ event: DiagnosticsObservation) {
    guard isEnabled else { return }
    queue.record(event)
    if isForeground && queue.hasSealedBatch { drain() }
  }

  func recordLastDetection(
    displayID: String, rpid: String, timestamp: Date, reason: DiagnosticsDetectionReason
  ) {
    guard isEnabled else { return }
    guard let alias = queue.alias(forRpid: rpid) else {
      radarAliases.removeValue(forKey: displayID)
      return
    }
    let wall = Int64(timestamp.timeIntervalSince1970 * 1_000)
    // This short-lived association stays in memory with the live radar.
    if radarAliases[displayID] == nil, radarAliases.count >= 512,
      let oldest = radarAliases.min(by: { $0.value.lastSeen < $1.value.lastSeen })?.key
    {
      radarAliases.removeValue(forKey: oldest)
    }
    radarAliases[displayID] = (alias, wall)
    record(.lastDetectionUpdated(alias, wall: wall, reason: reason))
  }

  func recordRadarProjection(from previous: Set<String>, to current: Set<String>) {
    guard isEnabled, isForeground else { return }
    for displayID in current.subtracting(previous).sorted() {
      if let alias = radarAliases[displayID]?.alias { record(.radarPeerRendered(alias)) }
    }
    for displayID in previous.subtracting(current).sorted() {
      if let alias = radarAliases.removeValue(forKey: displayID)?.alias { record(.radarPeerRemoved(alias)) }
    }
  }

  func resetRadarAssociations() {
    radarAliases.removeAll()
  }

  func setClockCorrection(_ correction: DiagnosticsClockCorrection?) {
    queue.setClockCorrection(correction)
  }

  func setForeground(_ active: Bool) {
    guard isForeground != active else { return }
    isForeground = active
    guard isEnabled else { return }
    if active {
      record(.lifecycle(.foreground))
      startCadence()
    } else {
      cadence?.cancel()
      cadence = nil
      record(.lifecycle(.background))
    }
    flush()
  }

  func flush() {
    guard isEnabled else { return }
    queue.seal()
    drain()
  }

  func cancelUpload() {
    requestID = nil
    request?.cancel()
    request = nil
  }

  private func startCadence() {
    guard isForeground, cadence == nil else { return }
    cadence = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(30)) } catch { return }
        guard let self else { return }
        self.flush()
      }
    }
  }

  private func drain() {
    guard request == nil, let upload, let generation = queue.generation,
      ProcessInfo.processInfo.systemUptime >= retryAfter,
      let batch = queue.nextBatch(sealingDraft: false)
    else { return }
    let id = UUID()
    requestID = id
    request = Task { [weak self] in
      guard self?.queue.generation == generation, self?.requestID == id, !Task.isCancelled else { return }
      let retry: Bool
      do {
        let status = try await upload(batch.body)
        retry = status == 429 || (500...599).contains(status)
      } catch {
        retry = true
      }
      guard let self, !Task.isCancelled, queue.generation == generation, requestID == id else { return }
      request = nil
      requestID = nil
      if retry || !queue.removeBatch(batch.id) {
        retryCount = min(retryCount + 1, 8)
        let delay = TimeInterval(1 << retryCount)
        retryAfter = ProcessInfo.processInfo.systemUptime + delay * Double.random(in: 0.5...1)
      } else {
        retryCount = 0
        retryAfter = 0
        if isForeground { drain() }
      }
    }
  }
}

/// Uses a short-lived, non-background session and blocks redirects of the write credential.
final class DiagnosticsTransport: NSObject, URLSessionTaskDelegate {
  private let endpoint: URL
  private let writeToken: String

  init?(origin: String?, writeToken: String?) {
    guard let origin, var url = URLComponents(string: origin),
      url.scheme == "https", let host = url.host, !host.isEmpty,
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      url.path.isEmpty || url.path == "/",
      let writeToken, !writeToken.isEmpty, !writeToken.hasPrefix("$("),
      !writeToken.contains(where: { $0.isWhitespace })
    else { return nil }
    url.path = "/v1/diagnostics/batches"
    guard let endpoint = url.url else { return nil }
    self.endpoint = endpoint
    self.writeToken = writeToken
  }

  func upload(_ body: Data) async throws -> Int {
    try Task.checkCancellation()
    var request = URLRequest(url: endpoint, timeoutInterval: 15)
    request.httpMethod = "POST"
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(writeToken)", forHTTPHeaderField: "Authorization")

    let config = URLSessionConfiguration.ephemeral
    config.httpShouldSetCookies = false
    config.urlCredentialStorage = nil
    config.urlCache = nil
    let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (_, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    return response.statusCode
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
