// Use of this source code is governed by a BSD-style license.

import Barnard
import BarnardCore
import BeidLabCliCore
import Foundation

/// Joins an event, scans and advertises at once, and reports what resolved.
///
/// ## What this can and cannot be counted as
///
/// A Mac running this is an additional participant, not a substitute for a
/// phone. beid's own confirmation threshold counts distinct devices
/// (`shared/.../sensing/EventConfirmThreshold.kt`), so two Macs in the room
/// reduce how many phones a phone needs to see — which is the point — but the
/// four-device gate in beid#218 is unaffected.
///
/// ## The event-code gate decides whether any of this is visible
///
/// `BarnardEngine` reads B004 first and aborts on a mismatch before B002
/// (`BarnardEngine.swift:2088-2113` at v0.9.2), so a peer on a different
/// event code produces no detection at all — and a detection is what moves a
/// phone's count. That cuts both ways and both are useful:
///
/// - a run on a **synthetic** code cannot affect any phone's numbers, which
///   is what makes a rehearsal safe;
/// - a run that must be **counted** has to join the real code. There is no
///   synthetic shortcut, and whether a Mac may join a real event is not this
///   tool's decision to take.
///
/// Either way the `gatt_b004` lines say which happened, so a run that saw
/// nothing can be told apart from a run that was gated.
final class ParticipateRunner {
  private let options: LabOptions
  private let emitter: LabEmitter
  private let finish: (LabExit, LabResult, String, [String: LabValue]) -> Void
  private let engine = BarnardEngine()

  /// Distinct peer display ids, which is what "how many peers" means here.
  /// Detections are not it: one peer produces many.
  private var peers: Set<String> = []
  private var announcedDisplayId = false
  private var gateMatches = 0
  private var gateMismatches = 0
  /// The GATT lifecycle, counted rather than only logged.
  ///
  /// Run 2 on 2026-09-17 failed 18 resolutions out of 18 and that fact had to
  /// be reconstructed by counting lines in a `--log-level debug` capture. A
  /// run whose central resolved nothing should say so in its own closing
  /// line, at any level.
  private var connectAttempts = 0
  private var connectsCompleted = 0
  private var resolutionFailuresByReason: [String: Int] = [:]
  private var started = false
  private let startedAt = Date()

  init(
    options: LabOptions,
    emitter: LabEmitter,
    finish: @escaping (LabExit, LabResult, String, [String: LabValue]) -> Void
  ) {
    self.options = options
    self.emitter = emitter
    self.finish = finish
  }

  func start() {
    engine.onEvent = { [weak self] event in
      guard let self else { return }
      EngineLogging.log(event: event, to: self.emitter)
      self.observe(event)
    }
    engine.onDebugEvent = { [weak self] event in
      guard let self else { return }
      EngineLogging.log(debug: event, to: self.emitter)
      self.countGate(event)
    }

    // ENIN parameters are passed only when the operator asked for them.
    // Neither beid app calls `configure` with ENIN arguments, so leaving them
    // alone is what keeps this run comparable with the phones; overriding
    // them is for an event whose definition differs.
    let participate = options.participate
    let joinString: String
    switch resolveJoinString() {
    case .success(let resolved): joinString = resolved
    case .failure(let error):
      finish(.harness, .rejected, "\(error)", [:])
      return
    }
    emitter.emit(
      .runStart, at: .info,
      data: [
        "joinSource": .string(joinSourceName()),
        "joinStringIsCanonicalEventId": .bool(LabEventCode.looksCanonical(joinString)),
        // Redacted like any other join credential below `trace`: it gates
        // B004, so it is not something to leave lying in a shared log.
        "joinString": .string(LabRedaction.rpid(joinString, at: emitter.level)),
        "b004": .string(
          LabRedaction.hex(BarnardCoreCrypto.computeEventCodeHash(joinString))),
      ])
    if !LabEventCode.looksCanonical(joinString) {
      emitter.emit(
        .failure, at: .error, result: .mismatch,
        data: [
          "reason": .string("non_canonical_join_string"),
          "detail": .string(LabEventCode.syntheticRehearsalNote),
        ])
    }

    if participate.eninSeconds != nil || participate.eninMode != nil {
      engine.configure(
        eninMode: participate.eninMode.map { BarnardEninMode(rawValue: $0.rawValue)! }
          ?? .fixedLength,
        eninSeconds: participate.eninSeconds ?? 300,
        eventCode: joinString
      )
      emitter.emit(
        .runStart, at: .info,
        data: [
          "eninOverridden": .bool(true),
          "eninSeconds": participate.eninSeconds.map { .int($0) } ?? .null,
          "eninMode": participate.eninMode.map { .string($0.rawValue) } ?? .null,
        ])
    } else {
      engine.configure(eventCode: joinString)
    }

    if participate.relayEnabled {
      // The verifier reports REGISTRY_VERIFIED for any signature-valid
      // envelope with no registry read at all. That is a lab affordance for
      // making the relay path fire between machines we own, and the Barnard
      // README says plainly not to copy it into a product. `--relay on`
      // inherits that warning and says so in its own line.
      engine.configureParticipantRelay(verifier: LabPermissiveRelayVerifier())
      emitter.emit(
        .relay, at: .error,
        data: [
          "enabled": .bool(true),
          "verifier": .string("LabPermissiveRelayVerifier"),
          "warning": .string(
            "reports REGISTRY_VERIFIED with no registry read; lab use only, never a product"),
        ])
    }

    engine.requestPermissions { [weak self] status in
      guard let self else { return }
      self.emitter.emit(
        .permissions, at: .info,
        data: [
          "canScan": .bool(status.canScan),
          "canAdvertise": .bool(status.canAdvertise),
          "missing": .array(status.missingPermissions.map { .string($0) }),
          "blocked": .array(status.blockedPermissions.map { .string($0) }),
        ])
      if let blocker = LabBluetooth.blocker(), !LabBluetooth.authorizationIsUndecided {
        self.finish(.bluetoothUnavailable, .unavailable, blocker, self.summary())
        return
      }
      self.startRadio()
    }
  }

  private func startRadio() {
    started = true
    switch options.participate.role {
    case .advertise: engine.startAdvertise()
    case .scan: engine.startScan()
    case .auto: engine.startAuto()
    }
  }

  // MARK: Counting

  private func observe(_ event: BarnardEvent) {
    switch event {
    case .state(let state):
      // The display id is derived from the joined event's key, so it only
      // means anything once the radio is up. Release builds put no name on
      // the air, so this is the only handle a human has for "which box is
      // this" when reading two logs side by side.
      if !announcedDisplayId, state.isScanning || state.isAdvertising {
        announcedDisplayId = true
        emitter.emit(
          .runStart, at: .info,
          data: ["myDisplayId": .string(engine.getMyDisplayId()), "radioActive": .bool(true)])
      }
    case .detection(let detection):
      note(peer: detection.detectedDisplayId)
    case .rssiUpdate(let update):
      // A peer's display id arrives from a GATT read that completes after the
      // first advertisement, so it often lands on an update rather than on
      // the detection that opened the connection.
      note(peer: update.detectedDisplayId)
    default:
      break
    }
  }

  /// The B004 gate's tally, which is what separates "nothing was out there"
  /// from "everything out there was on another event" -- and the GATT
  /// lifecycle's, which separates both of those from "we never got a read
  /// through at all", the case run 2 hit.
  private func countGate(_ event: BarnardDebugEvent) {
    switch event.name {
    case "gatt_b004_mismatch":
      gateMismatches += 1
    case "gatt_read_event_code_hash":
      if let matches = event.data?["matches"] as? Bool, matches { gateMatches += 1 }
    case "connect_attempt":
      connectAttempts += 1
    case "connected":
      connectsCompleted += 1
    case "gatt_resolution_failed":
      let reason = (event.data?["reason"] as? String) ?? "unspecified"
      resolutionFailuresByReason[reason, default: 0] += 1
    case "gatt_exchange_timeout":
      resolutionFailuresByReason["exchange_timeout", default: 0] += 1
    default:
      break
    }
  }

  // MARK: Join source

  private func joinSourceName() -> String {
    switch options.participate.join {
    case .eventId: return "event_id"
    case .rawCode: return "event_code"
    case .container: return "container"
    case nil: return "none"
    }
  }

  /// Produces the exact string `BarnardEngine.joinEvent` receives.
  ///
  /// The container path reuses the same `BarnardB005EnvelopeV2.verify` call
  /// `venue` uses to describe what it serves, so the Event ID comes out of
  /// the signed bytes with no second decoder in this repository.
  private func resolveJoinString() -> Result<String, JoinSourceError> {
    switch options.participate.join {
    case .eventId(let normalized):
      return .success(normalized)
    case .rawCode(let raw):
      return .success(raw)
    case .container(let path):
      let container: [UInt8]
      do {
        container = try VenueRunner.load(.file(path))
      } catch {
        return .failure(.unreadable(path, "\(error)"))
      }
      guard let verified = BarnardB005EnvelopeV2.verify(
        container: container, currentEnin: nil,
        nameValidator: BarnardB005NativeDisplayNameNormalizer())
      else {
        return .failure(.notAVerifiableContainer(path))
      }
      guard let joinString = LabEventCode.joinString(
        forEventIdHex: LabRedaction.hex(verified.eventId))
      else {
        return .failure(.notAVerifiableContainer(path))
      }
      emitter.adoptEventId(String(joinString.prefix(8)))
      return .success(joinString)
    case nil:
      return .failure(.missing)
    }
  }

  enum JoinSourceError: Error, CustomStringConvertible {
    case missing
    case unreadable(String, String)
    case notAVerifiableContainer(String)

    var description: String {
      switch self {
      case .missing:
        return "no join source"
      case .unreadable(let path, let detail):
        return "cannot read container \(path): \(detail)"
      case .notAVerifiableContainer(let path):
        return
          "\(path) is not a verifiable B005 v2 container, so no Event ID can be taken from it"
      }
    }
  }

  private func note(peer displayId: String?) {
    guard let displayId, !displayId.isEmpty else { return }
    guard peers.insert(displayId).inserted else { return }
    emitter.emit(
      .peerFirstSeen, at: .info,
      data: [
        "peer": .string(displayId),
        "peers": .int(peers.count),
        "expectPeers": .int(options.participate.expectPeers),
      ])
    // Zero is a hold, and `count >= 0` is true of the very first peer, so the
    // rendezvous branch has to exclude it or the hold ends the moment
    // anything is seen.
    if options.participate.expectPeers > 0, peers.count >= options.participate.expectPeers {
      stopRadio()
      finish(.ok, .match, "peers=\(peers.count) expected=\(options.participate.expectPeers)", summary())
    }
  }

  // MARK: Finishing

  func finishOnTimeout() {
    stopRadio()
    if let blocker = LabBluetooth.blocker() {
      finish(.bluetoothUnavailable, .unavailable, blocker, summary())
      return
    }
    guard peers.count >= options.participate.expectPeers else {
      finish(
        .expectationNotMet, .timeout,
        "peers=\(peers.count) expected=\(options.participate.expectPeers) after \(Int(options.timeoutSeconds))s",
        summary())
      return
    }
    finish(.ok, .ok, "held for \(Int(options.timeoutSeconds))s peers=\(peers.count)", summary())
  }

  func finishOnSignal() {
    stopRadio()
    finish(.harness, .interrupted, "interrupted", summary())
  }

  private func stopRadio() {
    guard started else { return }
    started = false
    engine.dispose()
  }

  private func summary() -> [String: LabValue] {
    [
      "peers": .int(peers.count),
      "expectPeers": .int(options.participate.expectPeers),
      // Reported even when zero. A run with no peers and no mismatches saw
      // nothing; a run with no peers and many mismatches was gated, and those
      // are different findings that a peer count alone cannot tell apart.
      "b004Matches": .int(gateMatches),
      "b004Mismatches": .int(gateMismatches),
      // A run that never completed a GATT exchange reads as an empty room
      // unless these are on the closing line. Run 2 was 18 failures, 0
      // matches and 0 mismatches, and only the first number says why.
      "gattConnectAttempts": .int(connectAttempts),
      "gattConnectsCompleted": .int(connectsCompleted),
      "gattResolutionFailures": .int(resolutionFailuresByReason.values.reduce(0, +)),
      "gattFailureReasons": .array(
        resolutionFailuresByReason.keys.sorted().map {
          .string("\($0)=\(resolutionFailuresByReason[$0]!)")
        }),
      "elapsed": .double(((Date().timeIntervalSince(startedAt)) * 1000).rounded() / 1000),
    ]
  }
}
