import Foundation
import Network

final class LoopbackJSONRPCServer {
  enum Error: Swift.Error, Equatable { case timedOut, readyWithoutPort, alreadyStarted }

  /// One terminal result owns startup, including events arriving before the
  /// continuation is registered. Callbacks run outside the lock.
  final class StartupWaiter {
    typealias Outcome = Result<URL, Swift.Error>
    private let lock = NSLock()
    private var outcome: Outcome?
    private var completion: ((Outcome) -> Void)?

    func wait(_ completion: @escaping (Outcome) -> Void) {
      lock.lock()
      if let outcome {
        lock.unlock()
        completion(outcome)
      } else {
        precondition(self.completion == nil, "listener startup has only one waiter")
        self.completion = completion
        lock.unlock()
      }
    }

    func receive(_ state: NWListener.State, port: NWEndpoint.Port?) {
      switch state {
      case .ready:
        guard let port, port.rawValue != 0 else {
          complete(.failure(Error.readyWithoutPort))
          return
        }
        complete(.success(URL(string: "http://127.0.0.1:\(port.rawValue)")!))
      case .failed(let error): complete(.failure(error))
      case .cancelled: cancel()
      default: break
      }
    }

    func timeOut() { complete(.failure(Error.timedOut)) }
    func cancel() { complete(.failure(CancellationError())) }

    private func complete(_ outcome: Outcome) {
      lock.lock()
      guard self.outcome == nil else { lock.unlock(); return }
      self.outcome = outcome
      let completion = self.completion
      self.completion = nil
      lock.unlock()
      completion?(outcome)
    }
  }

  private let startup = StartupWaiter()
  private let listener: NWListener
  private let queue = DispatchQueue(label: "beid.tests.loopback-rpc")
  private let response: (Data) -> Data
  private let responseDelayNanoseconds: UInt64
  private let onRequest: (() -> Void)?
  private let lock = NSLock()
  private var bodies: [Data] = []
  private var methods: [String] = []
  private var rpcMethods: [String] = []
  private var rpcCallSelectors: [String] = []
  private var requestBytes = 0
  private var responseBytes = 0
  private var active: [ObjectIdentifier: NWConnection] = [:]
  private var didStart = false
  private var isStopped = false

  init(responseDelayNanoseconds: UInt64 = 0, onRequest: (() -> Void)? = nil, response: @escaping (Data) -> Data) throws {
    self.response = response
    self.responseDelayNanoseconds = responseDelayNanoseconds
    self.onRequest = onRequest
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(
      host: NWEndpoint.Host("127.0.0.1"), port: .any
    )
    listener = try NWListener(using: parameters)
  }

  var summary: String {
    lock.lock(); defer { lock.unlock() }
    let lengths = bodies.map(\.count).map(String.init).joined(separator: ",")
    return "requests=\(bodies.count),methods=\(methods.joined(separator: ",")),rpcMethods=\(rpcMethods.joined(separator: ",")),rpcCallSelectors=\(rpcCallSelectors.joined(separator: ",")),bodyBytes=[\(lengths)],requestBytes=\(requestBytes),responseBytes=\(responseBytes)"
  }

  func start() async throws -> URL {
    try lock.withLock {
      guard !didStart else { throw Error.alreadyStarted }
      guard !isStopped else { throw CancellationError() }
      didStart = true
    }
    listener.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      self.startup.receive(state, port: self.listener.port)
    }
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { connection.cancel(); return }
      self.accept(connection)
    }
    listener.start(queue: queue)

    // A finite safety bound, independent of the listener's callback queue.
    // Readiness itself is event-driven; there is no port polling or retry.
    let timeout = DispatchWorkItem { [startup] in startup.timeOut() }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30, execute: timeout)
    defer { timeout.cancel() }
    do {
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          startup.wait { continuation.resume(with: $0) }
        }
      } onCancel: {
        self.startup.cancel()
      }
    } catch {
      stop()
      throw error
    }
  }

  func stop() {
    startup.cancel()
    let connections = lock.withLock {
      isStopped = true
      let connections = Array(active.values)
      active.removeAll()
      return connections
    }
    listener.cancel()
    connections.forEach { $0.cancel() }
  }

  private func retire(_ connection: NWConnection) {
    lock.lock(); active.removeValue(forKey: ObjectIdentifier(connection)); lock.unlock()
    connection.cancel()
  }

  private func accept(_ connection: NWConnection) {
    let accepted = lock.withLock {
      guard !isStopped else { return false }
      active[ObjectIdentifier(connection)] = connection
      return true
    }
    guard accepted else { connection.cancel(); return }
    connection.start(queue: queue)
    receive(connection, buffer: Data())
  }

  private func receive(_ connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
      guard let self, error == nil else { self?.retire(connection); return }
      var bytes = buffer; if let data { bytes.append(data) }
      guard let separator = bytes.range(of: Data("\r\n\r\n".utf8)) else {
        if complete { self.retire(connection) } else { self.receive(connection, buffer: bytes) }
        return
      }
      let header = bytes[..<separator.lowerBound]
      let headerText = String(decoding: header, as: UTF8.self)
      let isChunked = headerText.lowercased().contains("transfer-encoding: chunked")
      let declaredLength = header.split(separator: 10).compactMap { line -> Int? in
        let text = String(decoding: line, as: UTF8.self)
        guard text.lowercased().hasPrefix("content-length:") else { return nil }
        return Int(text.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
      }.first ?? 0
      let start = separator.upperBound
      let body: Data
      if isChunked {
        guard let decoded = Self.decodeChunked(Data(bytes[start...] )) else {
          if complete { self.retire(connection) } else { self.receive(connection, buffer: bytes) }
          return
        }
        body = decoded
      } else {
        guard headerText.lowercased().contains("content-length:") else {
          if complete { self.retire(connection) } else { self.receive(connection, buffer: bytes) }
          return
        }
        guard bytes.count >= start + declaredLength else { return self.receive(connection, buffer: bytes) }
        body = Data(bytes[start..<(start + declaredLength)])
      }
      let method = headerText.split(separator: " ").first.map(String.init) ?? "?"
      self.lock.lock()
      self.bodies.append(body); self.methods.append(method)
      if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
        let rpcMethod = object["method"] as? String {
        self.rpcMethods.append(rpcMethod)
        if rpcMethod == "eth_call",
          let params = object["params"] as? [Any],
          let call = params.first as? [String: Any],
          let data = (call["data"] as? String) ?? (call["input"] as? String) {
          self.rpcCallSelectors.append(String(data.prefix(10)))
        } else if rpcMethod == "eth_call" {
          let text = String(decoding: body, as: UTF8.self)
          if let marker = text.range(of: "\"input\":\"") ?? text.range(of: "\"data\":\"") {
            let remainder = text[marker.upperBound...]
            let value = remainder.prefix { $0 != "\"" }
            self.rpcCallSelectors.append(String(value.prefix(10)))
          }
        }
      }
      self.requestBytes += bytes.count
      self.lock.unlock()
      self.onRequest?()
      if self.responseDelayNanoseconds > 0 {
        usleep(useconds_t(min(self.responseDelayNanoseconds / 1_000, UInt64(UInt32.max))))
      }
      let payload = self.response(body)
      var output = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n".utf8)
      output.append(payload)
      connection.send(content: output, completion: .contentProcessed { [weak self] _ in
        self?.lock.lock(); self?.responseBytes += output.count; self?.lock.unlock()
        self?.retire(connection)
      })
    }
  }

  private static func decodeChunked(_ bytes: Data) -> Data? {
    var cursor = bytes.startIndex
    var output = Data()
    while true {
      guard let lineEnd = bytes[cursor...].range(of: Data("\r\n".utf8)) else { return nil }
      let line = String(decoding: bytes[cursor..<lineEnd.lowerBound], as: UTF8.self)
      guard let size = Int(line.split(separator: ";", maxSplits: 1).first ?? "", radix: 16) else { return nil }
      cursor = lineEnd.upperBound
      guard bytes.count >= cursor + size + 2 else { return nil }
      if size == 0 { return Data(output) }
      output.append(bytes[cursor..<(cursor + size)])
      guard bytes[cursor + size..<(cursor + size + 2)] == Data("\r\n".utf8) else { return nil }
      cursor += size + 2
    }
  }
}
