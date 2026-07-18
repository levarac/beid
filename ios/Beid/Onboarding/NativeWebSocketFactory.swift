// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation
import WalletConnectSign // re-exports WalletConnectRelay's WebSocketConnecting/WebSocketFactory

/// `URLSessionWebSocketTask`-backed adapter for reown-swift's pluggable
/// relay transport. reown-swift doesn't bundle a WebSocket implementation
/// itself — its own example app wires up Starscream (stale, last release
/// 2024-03) — so this uses the platform's native WebSocket task instead of
/// adding a third-party dependency.
final class NativeWebSocketFactory: WebSocketFactory {
  func create(with url: URL) -> WebSocketConnecting {
    NativeWebSocket(url: url)
  }
}

final class NativeWebSocket: NSObject, WebSocketConnecting {
  var isConnected = false
  var onConnect: (() -> Void)?
  var onDisconnect: ((Error?) -> Void)?
  var onText: ((String) -> Void)?
  var request: URLRequest

  private var task: URLSessionWebSocketTask?

  // Lifecycle note (#39): URLSession strongly retains its delegate until
  // invalidated, so using `self` here forms a retain cycle. In beid that
  // cycle is bounded to one process-lifetime instance: the shared wallet
  // client configures Reown once, and Reown's static Relay instance creates
  // one socket that its Dispatcher reuses across reconnects.
  //
  // Do not invalidate this session from `disconnect()`: that is a temporary
  // transport disconnect, and the same NativeWebSocket must create the next
  // URLSessionWebSocketTask. A `deinit`-only invalidate cannot break this
  // cycle either, because the session's delegate reference prevents deinit
  // from being reached. If this socket ever gains a finite owner, add an
  // explicit terminal shutdown owned by that owner (or use a weak delegate
  // proxy), separate from reconnect-cycle disconnects.
  private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

  init(url: URL) {
    self.request = URLRequest(url: url)
  }

  func connect() {
    let task = session.webSocketTask(with: request)
    self.task = task
    task.resume()
    receiveNext()
  }

  func disconnect() {
    task?.cancel(with: .normalClosure, reason: nil)
    task = nil
    isConnected = false
  }

  func write(string: String, completion: (() -> Void)?) {
    task?.send(.string(string)) { error in
      // WebSocketConnecting's `write` has no error channel to propagate
      // this through, so logging is the only signal available here.
      if let error {
        NSLog("NativeWebSocket write failed: \(error)")
      }
      completion?()
    }
  }

  private func receiveNext() {
    task?.receive { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let message):
        if case .string(let text) = message {
          self.onText?(text)
        }
        self.receiveNext()
      case .failure(let error):
        self.isConnected = false
        self.onDisconnect?(error)
      }
    }
  }
}

extension NativeWebSocket: URLSessionWebSocketDelegate {
  func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didOpenWithProtocol protocol: String?
  ) {
    isConnected = true
    onConnect?()
  }

  func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
    reason: Data?
  ) {
    isConnected = false
    onDisconnect?(nil)
  }
}
