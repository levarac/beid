import Foundation
import SwiftUI

struct LabControlIdentity: Equatable {
  let runId: String
  let role: String
  let deviceId: String
  let generation: Int
  let token: String
  let protocolVersion: Int

  init(runId: String, role: String, deviceId: String, generation: Int, token: String, protocolVersion: Int) throws {
    guard !runId.isEmpty, !role.isEmpty, !deviceId.isEmpty, !token.isEmpty else {
      throw LabBootstrapError.missingIdentity
    }
    guard generation >= 1 else { throw LabBootstrapError.invalidGeneration }
    guard protocolVersion == 1 else { throw LabBootstrapError.unsupportedProtocol }
    self.runId = runId; self.role = role; self.deviceId = deviceId
    self.generation = generation; self.token = token; self.protocolVersion = protocolVersion
  }
}

enum LabBootstrapError: LocalizedError {
  case missingIdentity, invalidGeneration, unsupportedProtocol, missingBroker
  var errorDescription: String? {
    switch self {
    case .missingIdentity: return "run_id, role, device_id, and token are required"
    case .invalidGeneration: return "generation is required"
    case .unsupportedProtocol: return "unsupported protocol_version"
    case .missingBroker: return "lab broker is not configured"
    }
  }
}

struct LabHello: Equatable {
  let identity: LabControlIdentity
  func wire() -> [String: Any] {
    ["type": "hello", "protocol_version": identity.protocolVersion,
     "run_id": identity.runId, "role": identity.role, "device_id": identity.deviceId,
     "generation": identity.generation, "token": identity.token]
  }
}

struct LabSnapshot: Equatable {
  let requestId: String
  let runId: String
  let role: String
  let deviceId: String
  let generation: Int
  let productionState: String
  let nearbyCandidates: [String]
  let records: [LabRecordMetadata]
}

protocol LabWebSocketClient {
  func connect(url: URL, hello: LabHello, productionState: @escaping () -> String,
               nearbyCandidates: @escaping () -> [String],
               records: @escaping () -> Result<[LabRecordMetadata], ReportSubmissionStore.LabRecordProjectionError>,
               joinNearbyEvent: @escaping (String, @escaping (Bool, String?) -> Void) -> Void,
               onSnapshot: @escaping (LabSnapshot) -> Void,
               onError: @escaping (String) -> Void)
  func stop()
}

/// Native client for the loopback host broker. It only answers snapshot requests.
final class URLSessionLabWebSocketClient: LabWebSocketClient {
  private var task: URLSessionWebSocketTask?
  private var consumedJoinRequestIds = Set<String>()

  func stop() {
    task?.cancel(with: .goingAway, reason: nil)
    task = nil
  }

  func connect(url: URL, hello: LabHello, productionState: @escaping () -> String,
               nearbyCandidates: @escaping () -> [String],
               records: @escaping () -> Result<[LabRecordMetadata], ReportSubmissionStore.LabRecordProjectionError>,
               joinNearbyEvent: @escaping (String, @escaping (Bool, String?) -> Void) -> Void,
               onSnapshot: @escaping (LabSnapshot) -> Void,
               onError: @escaping (String) -> Void) {
    let session = URLSession(configuration: .ephemeral)
    let task = session.webSocketTask(with: url)
    self.task = task
    task.resume()
    send(hello.wire(), on: task)
    receive(on: task, hello: hello, productionState: productionState, nearbyCandidates: nearbyCandidates,
            records: records,
            joinNearbyEvent: joinNearbyEvent, onSnapshot: onSnapshot, onError: onError)
  }

  private func send(_ object: [String: Any], on task: URLSessionWebSocketTask) {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object),
          let text = String(data: data, encoding: .utf8) else { return }
    task.send(.string(text)) { _ in }
  }

  private func receive(on task: URLSessionWebSocketTask, hello: LabHello,
                       productionState: @escaping () -> String,
                       nearbyCandidates: @escaping () -> [String],
                       records: @escaping () -> Result<[LabRecordMetadata], ReportSubmissionStore.LabRecordProjectionError>,
                       joinNearbyEvent: @escaping (String, @escaping (Bool, String?) -> Void) -> Void,
                       onSnapshot: @escaping (LabSnapshot) -> Void,
                       onError: @escaping (String) -> Void) {
    task.receive { [weak self] result in
      guard let self else { return }
      guard case .success(.string(let text)) = result else {
        onError("socket_receive_failed")
        return
      }
      guard let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        onError("invalid_json")
        return
      }
      if let commandType = object["type"] as? String, commandType == "join_nearby_event" {
        guard Set(object.keys) == ["type", "request_id", "run_id", "role", "device_id", "generation", "event_code_hash_hex"],
              let requestId = object["request_id"] as? String,
              let runId = object["run_id"] as? String,
              let role = object["role"] as? String,
              let deviceId = object["device_id"] as? String,
              let generation = object["generation"] as? Int,
              let hash = object["event_code_hash_hex"] as? String,
              runId == hello.identity.runId, role == hello.identity.role,
              deviceId == hello.identity.deviceId, generation == hello.identity.generation,
              nearbyCandidates().contains(hash) else {
          onError("join_nearby_event_rejected")
          return
        }
        guard consumedJoinRequestIds.insert(requestId).inserted else {
          self.send(["type": "join_nearby_event_result", "request_id": requestId,
                     "run_id": runId, "role": role, "device_id": deviceId,
                     "generation": generation, "status": "rejected", "reason": "duplicate_request",
                     "production_state": productionState()], on: task)
          return
        }
        joinNearbyEvent(hash) { [weak self] accepted, reason in
          guard let self else { return }
          self.send(["type": "join_nearby_event_result", "request_id": requestId,
                     "run_id": runId, "role": role, "device_id": deviceId,
                     "generation": generation, "status": accepted ? "accepted" : "rejected",
                     "reason": reason ?? NSNull(), "production_state": productionState()], on: task)
        }
        self.receive(on: task, hello: hello, productionState: productionState, nearbyCandidates: nearbyCandidates,
                     records: records,
                     joinNearbyEvent: joinNearbyEvent, onSnapshot: onSnapshot, onError: onError)
        return
      }
      guard
            let type = object["type"] as? String,
            type == "snapshot_request",
            Set(object.keys) == ["type", "request_id", "run_id", "role", "generation"],
            let requestId = object["request_id"] as? String,
            let runId = object["run_id"] as? String,
            let role = object["role"] as? String,
            let generation = object["generation"] as? Int,
            runId == hello.identity.runId, role == hello.identity.role,
            generation == hello.identity.generation else { return }
      let state = productionState()
      guard case .success(let snapshotRecords) = records() else {
        onError("records_unavailable")
        return
      }
      self.send(["type": "snapshot_response", "request_id": requestId,
                 "run_id": hello.identity.runId, "role": hello.identity.role,
                 "device_id": hello.identity.deviceId, "generation": hello.identity.generation,
                 "production_state": state, "nearby_candidates": nearbyCandidates(),
                 "records": snapshotRecords.map { record -> [String: Any] in
                   ["window_id": record.windowId, "event_id": record.eventId,
                    "observation_digest": record.observationDigest ?? NSNull(),
                    "status": record.status, "receipt_stored": record.receiptStored,
                    "terminal_error": record.terminalError ?? NSNull()]
                 }], on: task)
      onSnapshot(LabSnapshot(requestId: requestId, runId: runId, role: role,
                             deviceId: hello.identity.deviceId, generation: generation,
                             productionState: state, nearbyCandidates: nearbyCandidates(), records: snapshotRecords))
      self.receive(on: task, hello: hello, productionState: productionState, nearbyCandidates: nearbyCandidates,
                   records: records,
                   joinNearbyEvent: joinNearbyEvent, onSnapshot: onSnapshot, onError: onError)
    }
  }
}

@MainActor
final class LabControlBootstrap: ObservableObject {
  @Published private(set) var status = "not_started"
  private let identity: LabControlIdentity?
  private weak var sensing: SensingCoordinator?
  private let brokerURL: URL?
  private let broker: LabWebSocketClient?

  init(identity: LabControlIdentity?, sensing: SensingCoordinator, brokerURL: URL?, broker: LabWebSocketClient?) {
    self.identity = identity; self.sensing = sensing; self.brokerURL = brokerURL; self.broker = broker
  }

  func start() {
    guard let identity else { status = LabBootstrapError.missingIdentity.localizedDescription; return }
    guard let brokerURL, let broker else { status = LabBootstrapError.missingBroker.localizedDescription; return }
    status = "connecting"
    broker.connect(url: brokerURL, hello: LabHello(identity: identity),
                   productionState: { [weak self] in
                     guard let phase = self?.sensing?.phase else { return "unknown" }
                     return String(describing: phase)
                   }, nearbyCandidates: { [weak self] in self?.sensing?.labJoinableEventCodeHashHexes() ?? [] },
                   records: { [weak self] in
                     self?.sensing?.labRecordProjection() ?? .failure(.unreadable)
                   },
                   joinNearbyEvent: { [weak self] hash, completion in
                     Task { @MainActor in
                       guard let self, self.sensing?.labJoinableEventCodeHashHexes().contains(hash) == true else {
                         completion(false, "candidate_not_currently_verified")
                         return
                       }
                       self.sensing?.joinNearbyEvent(eventCodeHashHex: hash)
                       completion(true, nil)
                     }
                   }, onSnapshot: { [weak self] snapshot in
      guard let self else { return }
      status = snapshot.runId == identity.runId && snapshot.role == identity.role &&
        snapshot.deviceId == identity.deviceId && snapshot.generation == identity.generation ? "connected" : "snapshot_identity_mismatch"
    }, onError: { [weak self] message in self?.status = "error:\(message)" })
  }

  func stop() {
    broker?.stop()
    status = "stopped"
  }
}
