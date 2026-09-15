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
}

protocol LabWebSocketClient {
  func connect(url: URL, hello: LabHello, productionState: @escaping () -> String,
               onSnapshot: @escaping (LabSnapshot) -> Void)
}

/// Native client for the loopback host broker. It only answers snapshot requests.
final class URLSessionLabWebSocketClient: LabWebSocketClient {
  private var task: URLSessionWebSocketTask?

  func connect(url: URL, hello: LabHello, productionState: @escaping () -> String,
               onSnapshot: @escaping (LabSnapshot) -> Void) {
    let session = URLSession(configuration: .ephemeral)
    let task = session.webSocketTask(with: url)
    self.task = task
    task.resume()
    send(hello.wire(), on: task)
    receive(on: task, hello: hello, productionState: productionState, onSnapshot: onSnapshot)
  }

  private func send(_ object: [String: Any], on task: URLSessionWebSocketTask) {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object),
          let text = String(data: data, encoding: .utf8) else { return }
    task.send(.string(text)) { _ in }
  }

  private func receive(on task: URLSessionWebSocketTask, hello: LabHello,
                       productionState: @escaping () -> String,
                       onSnapshot: @escaping (LabSnapshot) -> Void) {
    task.receive { [weak self] result in
      guard let self else { return }
      guard case .success(.string(let text)) = result,
            let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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
      self.send(["type": "snapshot_response", "request_id": requestId,
                 "run_id": hello.identity.runId, "role": hello.identity.role,
                 "device_id": hello.identity.deviceId, "generation": hello.identity.generation,
                 "production_state": state], on: task)
      onSnapshot(LabSnapshot(requestId: requestId, runId: runId, role: role,
                             deviceId: hello.identity.deviceId, generation: generation,
                             productionState: state))
      self.receive(on: task, hello: hello, productionState: productionState, onSnapshot: onSnapshot)
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
                   productionState: { [weak self] in String(describing: self?.sensing?.phase ?? .idle) }) { [weak self] snapshot in
      guard let self else { return }
      status = snapshot.runId == identity.runId && snapshot.role == identity.role &&
        snapshot.deviceId == identity.deviceId && snapshot.generation == identity.generation ? "connected" : "snapshot_identity_mismatch"
    }
  }
}
