// Use of this source code is governed by a BSD-style license.

import Barnard
import BeidLabCliCore
import Foundation

/// Identity this process is signed and granted Bluetooth under.
enum LabBundle {
  /// Must match `scripts/bundle.sh`. macOS keys the Bluetooth grant to this
  /// plus the code signature, so the two files agreeing is what makes the
  /// grant survive a rebuild.
  static let identifier = "org.levarac.beid.LabCli"
}

/// Turns Barnard's event and debug streams into log lines.
///
/// Shared by `venue` and `participate` because both drive a `BarnardEngine`
/// and both owe the same redaction rules. `observe` does not use it: it has
/// no engine.
///
/// ## Why this is a mapping and not a passthrough
///
/// The Barnard lab runner forwards every JSON-valid field a debug callback
/// carries. That is why its logs contain raw RPIDs, and why a field the SDK
/// adds tomorrow would be logged in full the day it appears. Ken's rule
/// (2026-09-17) is that key material never appears and an RPID appears in
/// full only at `trace`, and a passthrough cannot honour a rule about fields
/// it has never heard of.
///
/// So the rule here is stated over *shapes* rather than over a list of field
/// names that would go stale:
///
/// - numbers and booleans pass through by value; an identifier is not an Int
/// - a string under a key in `neutralStringKeys` passes through; those keys
///   carry SDK vocabulary (`reason`, `state`, `receiverState`, ...), not
///   identities
/// - **any other string is treated as potentially identifying** and is cut to
///   a prefix at `debug` and below, whether or not this file has heard of the
///   key
/// - at `trace` everything passes, which is what `trace` is for
///
/// The last two are the load-bearing pair: an unrecognised field degrades to
/// redacted rather than to logged.
enum EngineLogging {
  /// Keys whose string values are SDK vocabulary rather than identity.
  ///
  /// Everything absent from this set — `id`, `displayId`, `myDisplayId`,
  /// `name`, `localName`, `eventCode`, `eventCodeHash`, and anything added
  /// later — is redacted below `trace`.
  static let neutralStringKeys: Set<String> = [
    "beaconChain", "characteristic", "decision", "eninMode", "error", "reason",
    "receiverState", "serviceUuid", "state",
  ]

  // MARK: Events

  static func log(event: BarnardEvent, to emitter: LabEmitter) {
    switch event {
    case .state(let state):
      // `advertise_start` is the engine's own reason code and is kept
      // verbatim in `reasonCode`, but the stage is named for what actually
      // happened: advertising was requested. `BarnardEngine` sets
      // `isAdvertising` before the OS confirms anything and has no success
      // callback (docs/venue-serving-contract.md), so only a receiver proves
      // the air.
      let stage: LabStage =
        state.reasonCode == "advertise_start"
        ? .advertiseRequested : (state.isScanning && state.reasonCode == "scan_start" ? .scanStart : .state)
      emitter.emit(
        stage, at: .info,
        data: [
          "scanning": .bool(state.isScanning),
          "advertising": .bool(state.isAdvertising),
          "reasonCode": .string(state.reasonCode ?? "none"),
          "eventCode": state.eventCode.map { .string(LabRedaction.rpid($0, at: emitter.level)) }
            ?? .null,
        ])

    case .detection(let detection):
      emitter.emit(
        .detection, at: .info,
        data: [
          "rpid": .string(LabRedaction.rpid(detection.rpid, at: emitter.level)),
          "rssi": .int(detection.rssi),
          "enin": .int(Int(detection.enin)),
          "formatVersion": .int(detection.formatVersion),
          "peer": detection.detectedDisplayId.map { .string($0) } ?? .null,
        ])

    case .rssiUpdate(let update):
      emitter.emit(
        .detection, at: .debug,
        data: [
          "rpid": .string(LabRedaction.rpid(update.rpid, at: emitter.level)),
          "rssi": .int(update.rssi),
          "enin": .int(Int(update.enin)),
          "peer": update.detectedDisplayId.map { .string($0) } ?? .null,
          "update": .bool(true),
        ])

    case .error(let error):
      emitter.emit(
        .failure, at: .error,
        data: [
          "code": .string(error.code),
          "message": .string(error.message),
          "recoverable": error.recoverable.map { .bool($0) } ?? .null,
        ])

    case .constraint(let constraint):
      emitter.emit(
        .constraint, at: .info,
        data: [
          "code": .string(constraint.code),
          "message": constraint.message.map { .string($0) } ?? .null,
        ])

    case .eventInfoHint(let hint):
      // The display name is on the wire by design: it is what a participant
      // is shown. Logging it is not a disclosure, it is the point.
      emitter.emit(
        .envelopeV2, at: .info,
        data: [
          "hint": .bool(true),
          "eventDisplayName": .string(hint.eventInfo.eventDisplayName),
          "additionalNamesOmitted": .bool(hint.additionalNamesOmitted),
          "additionalEventsOmitted": .bool(hint.additionalEventsOmitted),
        ])

    case .eventInfoEnvelopeV2(let envelope):
      // RADIO_SELF_VERIFIED means the signature checks out. It does not mean
      // the event is registered; this SDK never assigns REGISTRY_VERIFIED.
      emitter.emit(
        .envelopeV2, at: .info,
        data: [
          "receiverState": .string(String(describing: envelope.receiverState)),
          "bytes": .int(envelope.rawContainer.count),
          "containerHex": LabRedaction.rawBytes(
            [UInt8](envelope.rawContainer), at: emitter.level),
        ])

    case .relayDecision(let decision):
      // The digest is a local dedup key, not an identifier of a person or a
      // device, so it is logged in full.
      emitter.emit(
        .relay, at: .info,
        data: [
          "decision": .string(decision.decision.rawValue),
          "hop": .int(decision.hop),
          "reason": .string(decision.reason),
          "payloadDigest": .string(LabRedaction.hex([UInt8](decision.payloadDigest))),
        ])
    }
  }

  // MARK: Debug callbacks

  static func log(debug event: BarnardDebugEvent, to emitter: LabEmitter) {
    // Some debug names are the run's finding rather than debug noise, and
    // they are promoted out of the generic stream: given their own stage so
    // they are greppable, and raised to `info` so a default-level log shows
    // them. Run 2 on 2026-09-17 failed every GATT resolution it attempted,
    // and reconstructing that needed a `--log-level debug` capture nobody had
    // asked for in advance. A run that resolved nothing should say so at the
    // level an operator actually runs.
    let stage: LabStage
    var level = LabLogLevel.debug
    var result = LabResult.ok
    switch event.name {
    case "gatt_read_event_code_hash", "gatt_respond_event_code_hash", "gatt_b004_mismatch":
      stage = .gattB004
      level = .info
      if let matches = event.data?["matches"] as? Bool {
        result = matches ? .match : .mismatch
      } else if event.name == "gatt_b004_mismatch" {
        result = .mismatch
      }
    case "connect_attempt", "connected", "connect_queue_full":
      stage = .gattConnect
    case "gatt_exchange_timeout":
      // Carries the engine's own `seconds`, which is the only way the
      // connect timeout becomes observable: the constant itself is private.
      stage = .gattResolution
      level = .info
      result = .timeout
    case "gatt_resolution_failed", "gatt_read_failed":
      stage = .gattResolution
      level = .info
      result = .rejected
    case "gatt_resolution_backoff":
      stage = .gattResolution
    default:
      stage = .engineDebug
    }
    guard emitter.wants(level) else { return }

    var data = mapped(event.data, at: emitter.level)
    // Nested under its own key rather than merged: debug payloads carry their
    // own `name` (a peer's advertised local name), which would otherwise
    // overwrite the event name and make the stream unreadable.
    data["event"] = .string(event.name)
    data["engineLevel"] = .string(event.level)
    emitter.emit(stage, at: .debug, result: result, data: data)
  }

  /// Applies the shape rule described on the type.
  static func mapped(_ raw: [String: Any]?, at level: LabLogLevel) -> [String: LabValue] {
    guard let raw else { return [:] }
    var mapped: [String: LabValue] = [:]
    for (key, value) in raw {
      switch value {
      case let number as Int: mapped[key] = .int(number)
      case let number as Bool: mapped[key] = .bool(number)
      case let number as Double: mapped[key] = .double(number)
      case let number as NSNumber: mapped[key] = .int(number.intValue)
      case let text as String:
        mapped[key] =
          level == .trace || neutralStringKeys.contains(key)
          ? .string(text) : .string(LabRedaction.rpid(text, at: level))
      case let bytes as Data:
        mapped[key] = LabRedaction.rawBytes([UInt8](bytes), at: level)
      default:
        // Named but not valued: an operator can see a field exists and ask
        // for it to be mapped, without this tool having guessed whether its
        // contents were safe to print.
        mapped[key] = .string("<unmapped>")
      }
    }
    return mapped
  }
}
