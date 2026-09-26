// SPDX-License-Identifier: MIT

import BeidLabCliCore
import Foundation

// Everything here runs on the main queue. `BarnardEngine` requires it,
// CoreBluetooth delivers its callbacks there, and the timeout and signal
// sources are attached to the same queue, so no engine call is ever made
// concurrently.

/// Owns the exit path so that every route out of the process — a rendezvous,
/// a timeout, a signal, a bad argument — writes exactly one `result` line and
/// then leaves.
final class LabSession {
  private let emitter: LabEmitter
  private var finished = false
  private var signalSources: [DispatchSourceSignal] = []

  init(emitter: LabEmitter) {
    self.emitter = emitter
  }

  func finish(_ code: LabExit, _ result: LabResult, _ detail: String, _ data: [String: LabValue]) {
    guard !finished else { return }
    finished = true
    var payload = data
    payload["exitCode"] = .int(Int(code.rawValue))
    emitter.emitResult(result, detail: detail, data: payload)
    exit(code.rawValue)
  }

  /// Signals go through dispatch sources rather than C handlers so that
  /// stopping the radio and writing the last line happen on the main queue
  /// like every other call.
  func installSignalHandlers(_ onSignal: @escaping () -> Void) {
    for signalNumber in [SIGTERM, SIGINT] {
      signal(signalNumber, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
      source.setEventHandler(handler: onSignal)
      source.resume()
      signalSources.append(source)
    }
  }
}

let arguments = Array(CommandLine.arguments.dropFirst())

// The emitter exists before parsing, because an argument error still owes a
// `result` line. The hints are read straight off the raw list: a malformed
// `--log` just produces no file, and a malformed `--log-level` just leaves
// the default.
var sinks: [LabLineSink] = [LabStandardOutputSink()]
if let logPath = LabOptions.logPathHint(arguments) {
  sinks.append(LabFileSink(path: logPath))
}

do {
  let options = try LabOptions.parse(arguments)
  let emitter = LabEmitter(
    level: options.logLevel,
    mode: options.subcommand,
    eventIdPrefix: options.eventIdPrefix,
    sinks: sinks
  )
  let session = LabSession(emitter: emitter)

  emitter.emit(
    .runStart, at: .info,
    data: [
      "subcommand": .string(options.subcommand.rawValue),
      "logLevel": .string(options.logLevel.rawValue),
      "timeoutSeconds": .double(options.timeoutSeconds),
      "log": options.logPath.map { .string($0) } ?? .null,
      "bundleId": .string(LabBundle.identifier),
      "barnard": .string("0.9.2"),
    ])

  // One of the three, each owning its own radio and its own finish.
  let onTimeout: () -> Void
  let onSignal: () -> Void
  switch options.subcommand {
  case .observe:
    let runner = ObserveRunner(options: options, emitter: emitter, finish: session.finish)
    onTimeout = runner.finishOnTimeout
    onSignal = runner.finishOnSignal
    runner.start()
  case .venue:
    let runner = VenueRunner(options: options, emitter: emitter, finish: session.finish)
    onTimeout = runner.finishOnTimeout
    onSignal = runner.finishOnSignal
    runner.start()
  case .participate:
    let runner = ParticipateRunner(options: options, emitter: emitter, finish: session.finish)
    onTimeout = runner.finishOnTimeout
    onSignal = runner.finishOnSignal
    runner.start()
  }

  session.installSignalHandlers(onSignal)
  DispatchQueue.main.asyncAfter(deadline: .now() + options.timeoutSeconds, execute: onTimeout)
  dispatchMain()
} catch LabArgumentError.helpRequested {
  // Asking how to run the thing is not a run, so there is no result line and
  // nothing to parse: usage on stdout, exit 0.
  print(LabOptions.usage)
  for sink in sinks { sink.close() }
  exit(LabExit.ok.rawValue)
} catch {
  FileHandle.standardError.write(Data((LabOptions.usage + "\n").utf8))
  let emitter = LabEmitter(
    level: LabOptions.logLevelHint(arguments),
    // Best effort: a command line whose first word is not a subcommand has
    // no mode to report, and `observe` is the honest stand-in for "read
    // nothing, did nothing".
    mode: LabOptions.subcommandHint(arguments) ?? .observe,
    eventIdPrefix: nil,
    sinks: sinks
  )
  emitter.emitResult(
    .rejected, detail: "\(error)",
    data: ["exitCode": .int(Int(LabExit.harness.rawValue))])
  exit(LabExit.harness.rawValue)
}
