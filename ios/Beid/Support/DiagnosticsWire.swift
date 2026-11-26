// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import CryptoKit
import Darwin
import Foundation

struct DiagnosticsAlias {
  fileprivate let hex: String
}

struct DiagnosticsTrial: Codable {
  let runID: UUID
  private let key: Data

  init?(code: String) {
    let parts = code.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2, let runID = UUID(uuidString: String(parts[0])),
      runID.uuidString.lowercased() == parts[0], parts[1].count == 64,
      parts[1] == parts[1].lowercased(), let key = Self.hexBytes(parts[1])
    else { return nil }
    self.runID = runID
    self.key = key
  }

  func alias(forRpid rpid: String) -> DiagnosticsAlias? {
    guard rpid.utf8.count == 34, let payload = Self.hexBytes(rpid[...]),
      payload.count == 17, payload.first == 1
    else { return nil }
    var input = Data("beid.diagnostics.v1/b002_rpid_v1".utf8)
    input.append(0)
    input.append(contentsOf: payload.dropFirst())
    let mac = HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: key))
    return DiagnosticsAlias(hex: mac.map { String(format: "%02x", $0) }.joined())
  }

  private static func hexBytes(_ text: Substring) -> Data? {
    let bytes = Array(text.utf8)
    guard bytes.count.isMultiple(of: 2) else { return nil }
    var result = Data()
    for index in stride(from: 0, to: bytes.count, by: 2) {
      guard let high = hexDigit(bytes[index]), let low = hexDigit(bytes[index + 1]) else { return nil }
      result.append(high * 16 + low)
    }
    return result
  }

  private static func hexDigit(_ ascii: UInt8) -> UInt8? {
    switch ascii {
    case 48...57: return ascii - 48
    case 65...70: return ascii - 55
    case 97...102: return ascii - 87
    default: return nil
    }
  }
}

struct DiagnosticsTimestamp: Equatable {
  let wall: Int64
  let monotonic: Int64

  static func now() -> Self {
    Self(
      wall: Int64(Date().timeIntervalSince1970 * 1_000),
      monotonic: Int64(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1_000_000)
    )
  }

  func needsNewAnchor(relativeTo anchor: Self) -> Bool {
    monotonic < anchor.monotonic || abs((wall - anchor.wall) - (monotonic - anchor.monotonic)) > 1_000
  }
}

struct DiagnosticsClockCorrection: Equatable {
  let sampledAt: DiagnosticsTimestamp
  let offset: Int64
  let uncertainty: Int64

  func isUsable(at timestamp: DiagnosticsTimestamp) -> Bool {
    !timestamp.needsNewAnchor(relativeTo: sampledAt) && timestamp.monotonic - sampledAt.monotonic < 300_000
  }
}

enum DiagnosticsLifecycle: String {
  case advertisingStarted = "advertising_started"
  case advertisingStopped = "advertising_stopped"
  case scanStarted = "scan_started"
  case scanStopped = "scan_stopped"
  case joined, left
  case stopRequested = "stop_requested"
  case stopConfirmed = "stop_confirmed"
  case relayEnabled = "relay_enabled"
  case relayDisabled = "relay_disabled"
  case foreground, background
}

enum DiagnosticsCharacteristic: String {
  case b002, b003, b004, b005
}

enum DiagnosticsOutcome: String {
  case success, failure
}

enum DiagnosticsDetectionReason: String {
  case detection, rssiUpdate = "rssi_update"
}

enum DiagnosticsObservation {
  case lifecycle(DiagnosticsLifecycle)
  case peerDetected(rpid: String, rssi: Int)
  case rssiUpdated(rpid: String, rssi: Int)
  case gattReadFinished(DiagnosticsCharacteristic, DiagnosticsOutcome)
  case windowOpened(Int)
  case windowClosed(Int)
  case lastDetectionUpdated(DiagnosticsAlias, wall: Int64, reason: DiagnosticsDetectionReason)
  case radarPeerRendered(DiagnosticsAlias)
  case radarPeerRemoved(DiagnosticsAlias)
}

struct DiagnosticsWireEvent: Encodable {
  let seq: Int64
  let wall_ms: Int64
  let monotonic_ms: Int64
  private(set) var kind: String
  private var characteristic: String?
  private var outcome: String?
  private var rssi_dbm: Int?
  private var window: Int?
  private var alias_kind: String?
  private var peer_alias: String?
  private var last_seen_ms: Int64?
  private var reason: String?

  init?(_ observation: DiagnosticsObservation, sequence: Int64, timestamp: DiagnosticsTimestamp, trial: DiagnosticsTrial) {
    self.seq = sequence
    self.wall_ms = timestamp.wall
    self.monotonic_ms = timestamp.monotonic
    kind = ""
    switch observation {
    case .lifecycle(let lifecycle):
      kind = lifecycle.rawValue
    case .peerDetected(let rpid, let rssi), .rssiUpdated(let rpid, let rssi):
      if case .peerDetected = observation { kind = "peer_detected" } else { kind = "rssi_updated" }
      guard let alias = trial.alias(forRpid: rpid) else { return nil }
      setAlias(alias)
      if (-127...20).contains(rssi) { rssi_dbm = rssi }
    case .gattReadFinished(let characteristic, let outcome):
      kind = "gatt_read_finished"
      self.characteristic = characteristic.rawValue
      self.outcome = outcome.rawValue
    case .windowOpened(let index), .windowClosed(let index):
      if case .windowOpened = observation { kind = "window_opened" } else { kind = "window_closed" }
      window = index
    case .lastDetectionUpdated(let alias, let wall, let reason):
      kind = "last_detection_updated"
      setAlias(alias)
      last_seen_ms = wall
      self.reason = reason.rawValue
    case .radarPeerRendered(let alias), .radarPeerRemoved(let alias):
      if case .radarPeerRendered = observation { kind = "radar_peer_rendered" } else { kind = "radar_peer_removed" }
      setAlias(alias)
    }
  }

  private mutating func setAlias(_ alias: DiagnosticsAlias) {
    alias_kind = "b002_rpid_v1"
    peer_alias = alias.hex
  }
}

struct DiagnosticsMetadata {
  var model = "unknown"
  var osVersion = "unknown"
  var appBuild = "unknown"
  var sourceSHA: String?
}

struct DiagnosticsWireBatch: Encodable {
  struct Clock: Encodable {
    let timestamp: DiagnosticsTimestamp
    let correction: DiagnosticsClockCorrection?

    private enum CodingKeys: String, CodingKey {
      case wall_ms, monotonic_ms, offset_ms, uncertainty_ms
    }

    func encode(to encoder: Encoder) throws {
      var values = encoder.container(keyedBy: CodingKeys.self)
      try values.encode(timestamp.wall, forKey: .wall_ms)
      try values.encode(timestamp.monotonic, forKey: .monotonic_ms)
      try values.encode(correction?.offset, forKey: .offset_ms)
      try values.encode(correction?.uncertainty, forKey: .uncertainty_ms)
    }
  }

  let batchID = UUID()
  let runID: UUID
  let debugID: UUID
  let metadata: DiagnosticsMetadata
  let anchor: DiagnosticsTimestamp
  let correction: DiagnosticsClockCorrection?
  var droppedEvents: Int64
  var events: [DiagnosticsWireEvent] = []

  private enum CodingKeys: String, CodingKey {
    case v, run_id, debug_id, batch_id, model, os_version, app_build, source_sha, clock_sync, dropped_events, events
  }

  func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(1, forKey: .v)
    try values.encode(runID.uuidString.lowercased(), forKey: .run_id)
    try values.encode(debugID.uuidString.lowercased(), forKey: .debug_id)
    try values.encode(batchID.uuidString.lowercased(), forKey: .batch_id)
    try values.encode(metadata.model, forKey: .model)
    try values.encode(metadata.osVersion, forKey: .os_version)
    try values.encode(metadata.appBuild, forKey: .app_build)
    try values.encode(metadata.sourceSHA, forKey: .source_sha)
    try values.encode(Clock(timestamp: anchor, correction: correction), forKey: .clock_sync)
    try values.encode(droppedEvents, forKey: .dropped_events)
    try values.encode(events, forKey: .events)
  }
}
