import Foundation
import Network

final class LoopbackJSONRPCServer {
  enum Error: Swift.Error { case timedOut }
  private let listener: NWListener
  private let queue = DispatchQueue(label: "beid.tests.loopback-rpc")
  private let response: (Data) -> Data
  private let lock = NSLock()
  private var bodies: [Data] = []
  private var methods: [String] = []
  private var requestBytes = 0
  private var responseBytes = 0
  private var active: [ObjectIdentifier: NWConnection] = [:]
  private var failed: Swift.Error?

  init(response: @escaping (Data) -> Data) throws {
    self.response = response
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(
      host: NWEndpoint.Host("127.0.0.1"), port: .any
    )
    listener = try NWListener(using: parameters)
  }

  var summary: String {
    lock.lock(); defer { lock.unlock() }
    let lengths = bodies.map(\.count).map(String.init).joined(separator: ",")
    return "requests=\(bodies.count),methods=\(methods.joined(separator: ",")),bodyBytes=[\(lengths)],requestBytes=\(requestBytes),responseBytes=\(responseBytes)"
  }

  func start() async throws -> URL {
    listener.stateUpdateHandler = { [weak self] state in
      if case .failed(let error) = state { self?.lock.lock(); self?.failed = error; self?.lock.unlock() }
    }
    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    listener.start(queue: queue)
    for _ in 0..<100 {
      lock.lock(); let error = failed; lock.unlock()
      if let error { throw error }
      if let port = listener.port, port.rawValue != 0 { return URL(string: "http://127.0.0.1:\(port.rawValue)")! }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw Error.timedOut
  }

  func stop() {
    listener.cancel()
    lock.lock(); let connections = Array(active.values); active.removeAll(); lock.unlock()
    connections.forEach { $0.cancel() }
  }

  private func accept(_ connection: NWConnection) {
    lock.lock(); active[ObjectIdentifier(connection)] = connection; lock.unlock()
    connection.start(queue: queue)
    receive(connection, buffer: Data())
  }

  private func receive(_ connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
      guard let self, error == nil else { connection.cancel(); return }
      var bytes = buffer; if let data { bytes.append(data) }
      guard let separator = bytes.range(of: Data("\r\n\r\n".utf8)) else {
        return complete ? connection.cancel() : self.receive(connection, buffer: bytes)
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
          return complete ? connection.cancel() : self.receive(connection, buffer: bytes)
        }
        body = decoded
      } else {
        guard headerText.lowercased().contains("content-length:") else {
          return complete ? connection.cancel() : self.receive(connection, buffer: bytes)
        }
        guard bytes.count >= start + declaredLength else { return self.receive(connection, buffer: bytes) }
        body = Data(bytes[start..<(start + declaredLength)])
      }
      let method = headerText.split(separator: " ").first.map(String.init) ?? "?"
      self.lock.lock()
      self.bodies.append(body); self.methods.append(method); self.requestBytes += bytes.count
      self.lock.unlock()
      let payload = self.response(body)
      var output = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n".utf8)
      output.append(payload)
      connection.send(content: output, completion: .contentProcessed { [weak self] _ in
        self?.lock.lock(); self?.responseBytes += output.count; self?.active.removeValue(forKey: ObjectIdentifier(connection)); self?.lock.unlock()
        connection.cancel()
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
