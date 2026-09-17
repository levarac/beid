// Use of this source code is governed by a BSD-style license.

import Barnard
import BarnardCore
import BeidLabCliCore
import Foundation

/// Serves a signed event-info container and advertises.
///
/// ## What this does and does not decide
///
/// The container arrives already signed. `configureOwnEventInfoEnvelopeV2`
/// serves those bytes verbatim — the SDK does not sign, re-encode or
/// re-verify them, only checks that they are a well-formed hop-zero container
/// — so this runner supplies bytes and performs no venue policy at all. It
/// does not choose a slice from a schedule, does not extend a deadline, and
/// does not treat reading a file as permission to serve.
///
/// That division is why `venue` takes a container rather than a venue bundle:
/// decoding a bundle and picking its current slice are shared decisions that
/// live in `shared/.../parallax/venue` and belong to both apps. Reimplementing
/// them here in Swift would be a second implementation of a decision the
/// ownership boundary in `AGENTS.md` gives to `shared/`, and issue #588's own
/// scope says the CLI is Barnard-only with no shared macOS build.
///
/// ## No event code
///
/// `configure(eventCode:)` is never called. A signed container is served
/// without the engine knowing any event code, exactly as
/// `BarnardVenueSignedContainerBroadcasting` does on iOS. Joining a code here
/// would put a participant B004 on the air next to real participants, and the
/// argument parser refuses `--event-code` for this subcommand for the same
/// reason.
final class VenueRunner {
  private let options: LabOptions
  private let emitter: LabEmitter
  private let finish: (LabExit, LabResult, String, [String: LabValue]) -> Void
  private let engine = BarnardEngine()
  private var started = false

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
    guard let source = options.venue.container else {
      finish(.harness, .rejected, "no container source", [:])
      return
    }

    let container: [UInt8]
    do {
      container = try Self.load(source)
    } catch {
      finish(.harness, .rejected, "\(error)", [:])
      return
    }

    // Structure is checked here as well as by the engine, so a bad file is
    // reported with the rule it broke instead of as an opaque install
    // failure. `validateStructure` is clock-independent and injects nothing,
    // which is what makes it safe to call before the radio exists.
    if let structureError = BarnardB005EnvelopeV2.validateStructure(container: container) {
      emitter.emit(
        .failure, at: .error, result: .rejected,
        data: [
          "reason": .string("container_structure"),
          "detail": .string(String(describing: structureError)),
          "bytes": .int(container.count),
        ])
      finish(.harness, .rejected, "container rejected: \(structureError)", [:])
      return
    }
    describe(container)

    engine.onEvent = { [weak self] event in
      guard let self else { return }
      EngineLogging.log(event: event, to: self.emitter)
    }
    engine.onDebugEvent = { [weak self] event in
      guard let self else { return }
      EngineLogging.log(debug: event, to: self.emitter)
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
        self.finish(.bluetoothUnavailable, .unavailable, blocker, [:])
        return
      }
      self.install(container)
    }
  }

  /// The clear-install-clear sequence, taken from
  /// `BarnardVenueSignedContainerBroadcasting.installAndStart` on iOS.
  ///
  /// Both clears are load bearing. `configureOwnEventInfoEnvelopeV2`
  /// documents that a rejected container leaves the previous bytes in place,
  /// so without the second clear a rejected replacement would leave an
  /// earlier event's signed bytes live on the air — the one outcome a venue
  /// device must never produce.
  private func install(_ container: [UInt8]) {
    try? engine.configureOwnEventInfoEnvelopeV2(container: nil)
    do {
      try engine.configureOwnEventInfoEnvelopeV2(container: Data(container))
    } catch {
      try? engine.configureOwnEventInfoEnvelopeV2(container: nil)
      emitter.emit(
        .failure, at: .error, result: .rejected,
        data: ["reason": .string("container_install_rejected"), "detail": .string("\(error)")])
      finish(.harness, .rejected, "engine refused the container: \(error)", [:])
      return
    }
    started = true
    engine.startAdvertise()
    // The engine's own `advertise_start` state event produces the
    // `advertise_requested` line; nothing is claimed about the air here.
  }

  func finishOnTimeout() {
    stopRadio()
    finish(.ok, .ok, "served for \(Int(options.timeoutSeconds))s", [:])
  }

  func finishOnSignal() {
    stopRadio()
    finish(.harness, .interrupted, "interrupted", [:])
  }

  private func stopRadio() {
    guard started else { return }
    engine.stopAdvertise()
    try? engine.configureOwnEventInfoEnvelopeV2(container: nil)
    emitter.emit(.advertiseStop, at: .info, data: ["cleared": .bool(true)])
    engine.dispose()
  }

  /// Says what the container claims about itself, so an operator who copied
  /// the wrong file finds out before the phones do.
  ///
  /// `currentEnin` is nil on purpose: whether the window is open now is the
  /// operator's call and the phones' check, not this tool's. Passing a clock
  /// reading would make the CLI quietly refuse a container it was told to
  /// serve.
  private func describe(_ container: [UInt8]) {
    var data: [String: LabValue] = ["bytes": .int(container.count)]
    if let scheduling = BarnardB005EnvelopeV2.schedulingFields(container: container) {
      data["validFromEnin"] = .int(Int(scheduling.validFromEnin))
      data["validThroughEnin"] = .int(Int(scheduling.validThroughEnin))
      data["relayExpiresAtEnin"] = .int(Int(scheduling.relayExpiresAtEnin))
      data["eninSeconds"] = .int(Int(scheduling.eninSeconds))
      // The window in wall-clock terms, because ENIN numbers are not
      // something an operator in a room can compare against a watch.
      let seconds = Int(scheduling.eninSeconds)
      if seconds > 0 {
        data["validFromUnix"] = .int(Int(scheduling.validFromEnin) * seconds)
        data["validThroughUnix"] = .int((Int(scheduling.validThroughEnin) + 1) * seconds - 1)
        data["nowUnix"] = .int(Int(Date().timeIntervalSince1970))
      }
    }
    if let verified = BarnardB005EnvelopeV2.verify(
      container: container, currentEnin: nil,
      nameValidator: BarnardB005NativeDisplayNameNormalizer())
    {
      let eventIdHex = LabRedaction.hex(verified.eventId)
      data["receiverState"] = .string(String(describing: verified.receiverState))
      data["eventDisplayName"] = .string(verified.eventDisplayName)
      data["joinMode"] = .int(Int(verified.joinMode))
      data["relayHopCount"] = .int(Int(verified.relayHopCount))
      data["eventIdFull"] = LabRedaction.rawBytes(verified.eventId, at: emitter.level)
      if let prefix = LabRedaction.eventIdPrefix(eventIdHex) {
        data["containerEventId"] = .string(prefix)
        emitter.adoptEventId(prefix)
      }
      emitter.emit(.venueReady, at: .info, result: .match, data: data)
    } else {
      // Structure passed and the signature did not. Worth serving anyway if
      // the operator says so — this tool does not own the decision — but not
      // worth leaving unsaid.
      data["receiverState"] = .string("UNVERIFIED")
      emitter.emit(.venueReady, at: .info, result: .mismatch, data: data)
    }
  }

  // MARK: Loading

  enum LoadError: Error, CustomStringConvertible {
    case unreadable(String)
    case empty(String)

    var description: String {
      switch self {
      case .unreadable(let path): return "cannot read container file \(path)"
      case .empty(let path): return "container file \(path) is empty"
      }
    }
  }

  static func load(_ source: LabContainerSource) throws -> [UInt8] {
    switch source {
    case .hex(let hex):
      return stride(from: 0, to: hex.count, by: 2).compactMap { offset in
        let start = hex.index(hex.startIndex, offsetBy: offset)
        let end = hex.index(start, offsetBy: 2)
        return UInt8(hex[start..<end], radix: 16)
      }
    case .file(let path):
      guard let data = FileManager.default.contents(atPath: path) else {
        throw LoadError.unreadable(path)
      }
      guard !data.isEmpty else { throw LoadError.empty(path) }
      return [UInt8](data)
    }
  }
}
