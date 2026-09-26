// SPDX-License-Identifier: MIT

import BeidLabCliCore
import CoreBluetooth
import Foundation

/// Records what is on the air without touching it.
///
/// ## Why this does not use `BarnardEngine`
///
/// The engine's scan is not passive. Every discovery that clears its RSSI
/// guard is enqueued for a connect (`BarnardEngine.swift:1912-1920` at
/// v0.9.2), and a connect leads to GATT reads. dispatch#66 asks whether a
/// venue really stopped emitting, and an instrument that connects to the
/// thing it is measuring is not measuring it. So this is a bare
/// `CBCentralManager` with one delegate callback and no connection path at
/// all — no `connect`, no `discoverServices`, no `readValue`.
///
/// `scripts/check_observe_never_connects.py` enforces that in CI, because the
/// property is invisible in a diff: adding a connect here would look like an
/// ordinary feature and would silently perturb every future measurement.
///
/// ## Why the service filter is not `nil`
///
/// An iOS app advertising in the background moves its service UUID into the
/// advertisement's overflow area, which CoreBluetooth surfaces only to a scan
/// that names that UUID. A `nil` filter therefore misses exactly the
/// backgrounded phones this is pointed at.
final class ObserveRunner: NSObject, CBCentralManagerDelegate {
  /// Barnard's discovery service, taken from `LabScanPolicy` rather than
  /// written here, so the value a test pins and the value the radio receives
  /// are the same string. See that type for why both scan parameters are
  /// worth pinning at all.
  static let discoveryServiceUUID = CBUUID(string: LabScanPolicy.discoveryServiceUUIDString)

  /// How often the loss deadline is checked. Finer than any useful
  /// `--lost-after`, coarse enough that the sweep is not the thing keeping
  /// the CPU awake.
  private static let sweepInterval: TimeInterval = 1

  private let options: LabOptions
  private let emitter: LabEmitter
  private let finish: (LabExit, LabResult, String, [String: LabValue]) -> Void

  private var central: CBCentralManager?
  private var ledger: ObserverLedger
  private var sweepTimer: DispatchSourceTimer?
  private let startedAt = Date()
  private var sightings = 0
  private var reportedUnavailable = false

  init(
    options: LabOptions,
    emitter: LabEmitter,
    finish: @escaping (LabExit, LabResult, String, [String: LabValue]) -> Void
  ) {
    self.options = options
    self.emitter = emitter
    self.finish = finish
    self.ledger = ObserverLedger(
      lostAfter: options.observe.lostAfterSeconds,
      repeatEvery: options.observe.repeatEverySeconds
    )
    super.init()
  }

  func start() {
    central = CBCentralManager(delegate: self, queue: .main)
  }

  /// The timeout path. Closes every open interval first, so a peripheral
  /// still advertising when the window ended has an end line and the log can
  /// be read as intervals.
  func finishOnTimeout() {
    let now = elapsed()
    for outcome in ledger.closeOut(at: now) { report(outcome, reason: "window_end") }
    if let blocker = bluetoothBlocker() {
      finish(.bluetoothUnavailable, .unavailable, blocker, summary())
      return
    }
    finish(.ok, .ok, "observed for \(Int(options.timeoutSeconds))s", summary())
  }

  func finishOnSignal() {
    let now = elapsed()
    for outcome in ledger.closeOut(at: now) { report(outcome, reason: "interrupted") }
    finish(.harness, .interrupted, "interrupted", summary())
  }

  // MARK: CBCentralManagerDelegate

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    emitter.emit(
      .state, at: .debug,
      data: ["central": .string(LabBluetooth.name(for: central.state)), "scanning": .bool(central.isScanning)]
    )
    guard central.state == .poweredOn else {
      // A refused or missing grant will not become a grant during this run,
      // so there is nothing to wait for. `notDetermined` is different: the
      // prompt may still be answered, so that case runs to the timeout.
      if let blocker = bluetoothBlocker(), !LabBluetooth.authorizationIsUndecided,
        !reportedUnavailable
      {
        reportedUnavailable = true
        finish(.bluetoothUnavailable, .unavailable, blocker, summary())
      }
      return
    }
    // `withServices` is never nil: see `LabScanPolicy`. Both arguments come
    // from there, and `scripts/check_observe_never_connects.py` cross-checks
    // this call against it -- a mutation to `nil` used to leave the entire
    // suite green (chk-beid-590).
    central.scanForPeripherals(
      withServices: [Self.discoveryServiceUUID],
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: LabScanPolicy.allowDuplicates]
    )
    emitter.emit(
      .scanStart, at: .info,
      data: [
        "service": .string(Self.discoveryServiceUUID.uuidString),
        "allowDuplicates": .bool(LabScanPolicy.allowDuplicates),
        "lostAfterSeconds": .double(options.observe.lostAfterSeconds),
        "repeatEverySeconds": .double(options.observe.repeatEverySeconds),
      ]
    )
    startSweeping()
  }

  func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    // No connect, ever. See the type comment.
    sightings += 1
    let now = elapsed()
    let id = peripheral.identifier.uuidString
    let rssi = RSSI.intValue

    if emitter.wants(.debug) {
      emitter.emit(.discovery, at: .debug, data: advertisementFields(advertisementData, id: id, rssi: rssi))
    }
    for outcome in ledger.observe(peripheral: id, at: now, rssi: rssi) {
      report(outcome, reason: "advertisement")
    }
  }

  // MARK: Emission

  /// An explicit whitelist, not a passthrough of `advertisementData`.
  ///
  /// The dictionary CoreBluetooth hands over is open-ended, and forwarding it
  /// wholesale is how a field added by a future OS ends up in a log nobody
  /// meant to widen.
  private func advertisementFields(
    _ advertisementData: [String: Any], id: String, rssi: Int
  ) -> [String: LabValue] {
    var fields: [String: LabValue] = [
      "peer": .string(id),
      "rssi": .int(rssi),
    ]

    let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
    fields["services"] = .array(services.map { .string($0.uuidString) })

    let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
    // Whether a name is on the wire at all is the question the investigation
    // left open (a computer name would be a device-unique persistent
    // identifier, which AGENTS.md forbids on wire). The boolean answers it at
    // `debug`; the value itself is a `trace` decision.
    fields["localNamePresent"] = .bool(localName != nil)
    fields["localName"] = emitter.wants(.trace) && localName != nil
      ? .string(localName!) : .null

    if let connectable = advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber {
      fields["connectable"] = .bool(connectable.boolValue)
    }
    if let txPower = advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber {
      fields["txPower"] = .int(txPower.intValue)
    }

    let serviceData = (advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]) ?? [:]
    fields["serviceDataBytes"] = .int(serviceData.values.reduce(0) { $0 + $1.count })
    let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
    fields["manufacturerDataBytes"] = .int(manufacturerData?.count ?? 0)

    if emitter.wants(.trace) {
      // Advertisement payloads are public by construction: anything here was
      // broadcast to the room. Barnard puts nothing but a service UUID on the
      // air, so a non-empty value in these fields is itself the finding.
      fields["serviceDataHex"] = .array(
        serviceData.keys.sorted { $0.uuidString < $1.uuidString }.map {
          .string("\($0.uuidString)=\(LabRedaction.hex([UInt8](serviceData[$0]!)))")
        })
      fields["manufacturerDataHex"] = LabRedaction.rawBytes(
        [UInt8](manufacturerData ?? Data()), at: .trace)
    }
    return fields
  }

  private func report(_ outcome: ObserverOutcome, reason: String) {
    switch outcome {
    case .firstSeen(let id, let at, let rssi):
      emitter.emit(
        .peerFirstSeen, at: .info,
        data: ["peer": .string(id), "rssi": .int(rssi), "elapsed": .double(rounded(at))])
    case .seen(let id, let at, let rssi):
      emitter.emit(
        .discovery, at: .info,
        data: ["peer": .string(id), "rssi": .int(rssi), "elapsed": .double(rounded(at))])
    case .lost(let id, let lastSeenAt, let at):
      // `lastSeen` is the measurement dispatch#66 wants: the last moment
      // anything arrived. `elapsed` is only when the deadline fell due, which
      // is `--lost-after` later by construction.
      emitter.emit(
        .peerLost, at: .info,
        data: [
          "peer": .string(id),
          "lastSeen": .double(rounded(lastSeenAt)),
          "elapsed": .double(rounded(at)),
          "quietSeconds": .double(rounded(at - lastSeenAt)),
          "reason": .string(reason),
        ])
    }
  }

  private func summary() -> [String: LabValue] {
    [
      "peripherals": .int(ledger.distinctPeripheralCount),
      "stillActive": .int(ledger.activePeripheralCount),
      "advertisements": .int(sightings),
      "elapsed": .double(rounded(elapsed())),
    ]
  }

  // MARK: Plumbing

  private func startSweeping() {
    guard sweepTimer == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + Self.sweepInterval, repeating: Self.sweepInterval)
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      for outcome in self.ledger.sweep(at: self.elapsed()) {
        self.report(outcome, reason: "quiet")
      }
    }
    timer.resume()
    sweepTimer = timer
  }

  private func elapsed() -> TimeInterval { Date().timeIntervalSince(startedAt) }

  /// Milliseconds are the finest thing a timestamp in this log carries, so
  /// durations are rounded to match rather than printing float noise.
  private func rounded(_ value: TimeInterval) -> Double { (value * 1000).rounded() / 1000 }

  private func bluetoothBlocker() -> String? {
    LabBluetooth.blocker(managerStates: central.map { [$0.state] } ?? [])
  }

}
