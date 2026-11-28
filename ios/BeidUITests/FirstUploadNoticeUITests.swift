// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Foundation
import Network
import XCTest

@MainActor
final class FirstUploadNoticeUITests: XCTestCase {
  func testFirstNoticeExplainsUploadAndContinueSendsSavedBytes() async throws {
    let (app, receiver) = try await launch()
    defer { receiver.stop() }
    let notice = requireNotice(app)
    app.staticTexts["Before your first upload"].assertExists()
    app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "public verification API")).firstMatch.assertExists()
    app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "even at small events")).firstMatch.assertExists()
    app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Backups may retain a copy"))
      .firstMatch.scrollToHittable(in: app, within: notice, ignoringBackgroundTabBar: true)
    app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "does not delete observations you already sent"))
      .firstMatch.assertExists()
    app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "hi@levarac.org")).firstMatch.assertExists()
    policyLink(in: app).scrollToHittable(in: app, within: notice, ignoringBackgroundTabBar: true)
    attach("first-upload-notice")
    await assertQuiet(receiver)
    continueNotice(app)
    assertAccepted(app)
    XCTAssertEqual(receiver.posts, [FirstUploadWireSample.first.observation])
    XCTAssertEqual(receiver.gets, 0)
  }

  func testCloseKeepsThePreparedReportAndAllowsARepeatNotice() async throws {
    let (app, receiver) = try await launch()
    defer { receiver.stop() }
    requireNotice(app)
    closeNotice(app)
    XCTAssertEqual(app.staticTexts["firstUpload.fixture.state"].label, "PREPARED")
    await assertQuiet(receiver)
    sendToBackgroundAndReturn(app)
    requireNotice(app)
    await assertQuiet(receiver)
    continueNotice(app)
    assertAccepted(app)
    XCTAssertEqual(receiver.posts, [FirstUploadWireSample.first.observation])
  }

  func testPolicyLinkUsesTheApprovedURLWithoutReleasingTheQueue() async throws {
    let (app, receiver) = try await launch()
    defer { receiver.stop() }
    let notice = requireNotice(app)
    let link = policyLink(in: app)
    link.scrollToHittable(in: app, within: notice, ignoringBackgroundTabBar: true)
    // Still a link, announced by its title, drawn as the design-system text
    // control rather than as body text.
    XCTAssertEqual(link.elementType, .link)
    XCTAssertEqual(link.label, "Privacy Policy")
    XCTAssertGreaterThanOrEqual(link.frame.height, 44)
    link.tap()
    await assertQuiet(receiver)
    closeNotice(app)
    let opened = app.staticTexts["firstUpload.fixture.policyURL"]
    opened.assertExists()
    XCTAssertEqual(opened.label, "https://levarac.org/privacy")
    XCTAssertEqual(app.staticTexts["firstUpload.fixture.state"].label, "PREPARED")
    app.buttons["firstUpload.fixture.recheck"].tap()
    requireNotice(app)
    await assertQuiet(receiver)
    continueNotice(app)
    assertAccepted(app)
    XCTAssertEqual(receiver.posts, [FirstUploadWireSample.first.observation])
  }

  func testBackgroundAndRelaunchKeepTheGateUntilContinue() async throws {
    let (app, receiver) = try await launch()
    defer { receiver.stop() }
    let environment = app.launchEnvironment
    requireNotice(app)
    sendToBackgroundAndReturn(app)
    requireNotice(app)
    XCTAssertEqual(app.buttons.matching(identifier: "firstUpload.continue").count, 1)
    await assertQuiet(receiver)

    app.terminate()
    app.launch()
    requireNotice(app)
    await assertQuiet(receiver)
    continueNotice(app)
    assertAccepted(app)
    XCTAssertEqual(receiver.posts, [FirstUploadWireSample.first.observation])

    app.terminate()
    let next = FirstUploadWireSample.second
    app.launchEnvironment = environment.merging([
      "BEID_FIRST_UPLOAD_UI_RECORD": next.id, "BEID_FIRST_UPLOAD_UI_OBSERVATION": next.hex
    ]) { _, new in new }
    app.launch()
    assertAccepted(app)
    XCTAssertFalse(app.buttons["firstUpload.continue"].exists)
    XCTAssertEqual(receiver.posts, [FirstUploadWireSample.first.observation, next.observation])
    XCTAssertEqual(receiver.gets, 0)
  }

  func testExistingModalsKeepTheirPresentationUntilDismissed() async throws {
    for modal in [
      ("account", "home.account", "account.aboutSensing", "Done"),
      ("eventCode", "firstUpload.fixture.eventCode", "eventCode.title", "Cancel"),
      ("welcome", "welcome.howItWorks", "aboutSensing.whatWeSend", "Done")
    ] {
      let (app, receiver) = try await launch(mode: modal.0)
      defer { receiver.stop() }
      let opener = app.buttons[modal.1]
      opener.assertHittable()
      opener.tap()
      if modal.0 == "welcome" {
        app.buttons[modal.3].assertHittable()
      } else {
        app.descendants(matching: .any)[modal.2].assertExists()
      }
      XCTAssertFalse(app.buttons["firstUpload.continue"].exists)
      await assertQuiet(receiver)
      app.buttons[modal.3].assertHittable()
      app.buttons[modal.3].tap()
      requireNotice(app)
      await assertQuiet(receiver)
      continueNotice(app)
      let posted = await receiver.waitForPosts(1)
      XCTAssertTrue(posted, "No POST after dismissing \(modal.0)")
      assertAccepted(app)
      XCTAssertEqual(receiver.posts, [FirstUploadWireSample.first.observation])
      XCTAssertEqual(receiver.gets, 0)
      app.terminate()
    }
  }

  func testRecordsOpensTheSameSavedRecordBeforeAndAfterUpload() async throws {
    let (app, receiver) = try await launch()
    defer { receiver.stop() }
    requireNotice(app)
    closeNotice(app)
    openRecord(app)
    attach("first-upload-record-before")
    await assertQuiet(receiver)
    app.navigationBars.buttons.firstMatch.tap()
    app.buttons["firstUpload.fixture.recheck"].tap()
    requireNotice(app)
    continueNotice(app)
    assertAccepted(app)
    openRecord(app)
    attach("first-upload-record-after")
    XCTAssertEqual(receiver.posts, [FirstUploadWireSample.first.observation])
    XCTAssertEqual(receiver.gets, 0)
  }

  private func launch(mode: String = "automatic") async throws -> (XCUIApplication, FirstUploadLoopbackReceiver) {
    continueAfterFailure = false
    let receiver = try FirstUploadLoopbackReceiver()
    do {
      let port = try await receiver.start()
      let app = XCUIApplication()
      app.launchArguments = ["-beid-ui-test", "-beid-first-upload-ui", "-beid-home-frame-04"]
      let sample = FirstUploadWireSample.first
      app.launchEnvironment = [
        "BEID_FIRST_UPLOAD_UI_RUN": UUID().uuidString,
        "BEID_FIRST_UPLOAD_UI_MODE": mode,
        "BEID_FIRST_UPLOAD_UI_PORT": String(port),
        "BEID_FIRST_UPLOAD_UI_RECORD": sample.id,
        "BEID_FIRST_UPLOAD_UI_OBSERVATION": sample.hex
      ]
      app.launch()
      return (app, receiver)
    } catch {
      receiver.stop()
      throw error
    }
  }

  @discardableResult
  private func requireNotice(_ app: XCUIApplication) -> XCUIElement {
    let notice = app.scrollViews["firstUpload.notice"]
    notice.assertExists()
    app.buttons["firstUpload.continue"].assertExists()
    return notice
  }

  private func continueNotice(_ app: XCUIApplication) {
    let notice = requireNotice(app)
    let button = app.buttons["firstUpload.continue"]
    button.scrollToHittable(in: app, within: notice, ignoringBackgroundTabBar: true)
    button.tap()
  }

  private func closeNotice(_ app: XCUIApplication) {
    app.buttons["firstUpload.close"].assertHittable()
    app.buttons["firstUpload.close"].tap()
    app.buttons["firstUpload.fixture.recheck"].assertHittable()
  }

  private func policyLink(in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: "firstUpload.privacyPolicy").firstMatch
  }

  private func assertAccepted(_ app: XCUIApplication) {
    let state = app.staticTexts.matching(identifier: "firstUpload.fixture.state")
      .matching(NSPredicate(format: "label == %@", "ACCEPTED")).firstMatch
    XCTAssertTrue(state.existsOrWait(timeout: 45), "The normal runtime did not accept the fixture receipt")
  }

  private func sendToBackgroundAndReturn(_ app: XCUIApplication) {
    XCUIDevice.shared.press(.home)
    app.activate()
  }

  private func assertQuiet(_ receiver: FirstUploadLoopbackReceiver) async {
    // The gate assertion is paired with a positive POST and verified receipt
    // in each case so a broken transport cannot make the silence pass alone.
    try? await Task.sleep(for: .milliseconds(300))
    XCTAssertTrue(receiver.posts.isEmpty)
    XCTAssertEqual(receiver.gets, 0)
  }

  private func attach(_ name: String) {
    let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    screenshot.name = name
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  private func openRecord(_ app: XCUIApplication) {
    app.tabButton("Records").tap()
    let tiles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "records.record."))
    let tile = tiles["records.record.\(FirstUploadWireSample.first.id.uppercased())"]
    tile.assertHittable()
    XCTAssertEqual(tiles.count, 1)
    tile.tap()
    app.scrollViews["proof.detail.content"].assertExists()
    app.staticTexts["Record ID \(FirstUploadWireSample.first.id.uppercased())"].assertExists()
  }
}

/// A loopback-only receiver in the test runner, separate from the app's process.
/// Static receipts correspond to the two signed synthetic Observations.
private final class FirstUploadLoopbackReceiver: @unchecked Sendable {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "beid.ui.first-upload.receiver")
  private let lock = NSLock()
  private var port: UInt16?
  private var postBodies: [Data] = []
  private var getCount = 0

  var posts: [Data] { lock.withLock { postBodies } }
  var gets: Int { lock.withLock { getCount } }

  init() throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: parameters)
  }

  func start() async throws -> UInt16 {
    listener.stateUpdateHandler = { [weak self] state in
      guard let self, case .ready = state else { return }
      self.lock.withLock { self.port = self.listener.port?.rawValue }
    }
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else {
        connection.cancel()
        return
      }
      connection.start(queue: self.queue)
      self.receive(on: connection, bytes: Data())
    }
    listener.start(queue: queue)
    for _ in 0..<200 {
      if let port = lock.withLock({ port }), port != 0 { return port }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw URLError(.cannotConnectToHost)
  }

  func stop() { listener.cancel() }

  func waitForPosts(_ count: Int) async -> Bool {
    for _ in 0..<450 {
      if posts.count >= count { return true }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return false
  }

  private func receive(on connection: NWConnection, bytes: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
      [weak self] data, _, isComplete, error in
      guard let self, error == nil else {
        connection.cancel()
        return
      }
      var buffer = bytes
      if let data { buffer.append(data) }
      guard buffer.count <= 65_536 else { connection.cancel(); return }
      if self.respond(on: connection, bytes: buffer) { return }
      if isComplete { connection.cancel(); return }
      self.receive(on: connection, bytes: buffer)
    }
  }

  private func respond(on connection: NWConnection, bytes: Data) -> Bool {
    guard let end = bytes.range(of: Data([13, 10, 13, 10])) else { return false }
    let lines = String(decoding: bytes[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
    let parts = lines[0].split(separator: " ")
    guard parts.count >= 2 else { connection.cancel(); return true }
    let length = lines.first { $0.lowercased().hasPrefix("content-length:") }
      .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
    guard (0...65_536).contains(length) else { connection.cancel(); return true }
    guard bytes.count >= end.upperBound + length else { return false }
    let body = Data(bytes[end.upperBound..<(end.upperBound + length)])
    let receipt: Data?
    if parts[0] == "POST", parts[1] == "/v1/observations" {
      lock.withLock { postBodies.append(body) }
      receipt = [FirstUploadWireSample.first, .second].first { $0.observation == body }?.receipt
    } else {
      if parts[0] == "GET" { lock.withLock { getCount += 1 } }
      receipt = nil
    }
    let payload = receipt ?? Data()
    let status = receipt == nil ? "404 Not Found" : "201 Created"
    let headers = "HTTP/1.1 \(status)\r\nContent-Type: application/vnd.levarac.acceptance-receipt+cose\r\n" +
      "Content-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
    var response = Data(headers.utf8)
    response.append(payload)
    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    return true
  }
}

private struct FirstUploadWireSample: Sendable {
  let id: String
  let hex: String
  let receipt: Data

  var observation: Data {
    var bytes = Data()
    var remaining = hex[...]
    while !remaining.isEmpty {
      bytes.append(UInt8(remaining.prefix(2), radix: 16)!)
      remaining = remaining.dropFirst(2)
    }
    return bytes
  }

  // Synthetic vectors derived from the shared #701 Observation payload.
  // Both Observation and receipt signatures are checked by the reference codec.
  static let first = FirstUploadWireSample(
    id: "93600000-0000-4000-8000-000000000931",
    hex:
    "d2845839a301382e0378286170706c69636174696f6e2f766e642e6c6576617261632e6f62736572766174696f6e2b63626f" +
    "7204485ef036280edf16eba0590117a801010250936000000000400080000000000009310378196c6576617261632e6d7574" +
    "75616c2d73656e73696e672f7631045820111111111111111111111111111111111111111111111111111111111111111105" +
    "58210279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798061a69c485d8075101aaaaaaaaaaaa" +
    "aaaaaaaaaaaaaaaaaaaa085883a5015820222222222222222222222222222222222222222222222222222222222222222202" +
    "0703835101000000000000000000000000000000015101000000000000000000000000000000025101000000000000000000" +
    "0000000000000304f60558205c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c58409ac4812d" +
    "ad6d621c844bf922df8aff53f732a645549f2b364dcb14973c78fe0b77eb4e93b154d967d25e96c64cdf62bd15a1326d70eb" +
    "47da40a6250e0334bd81",
    receipt: Data(base64Encoded:
    "0oRYQKMBOC4DeC9hcHBsaWNhdGlvbi92bmQubGV2YXJhYy5hY2NlcHRhbmNlLXJlY2VpcHQrY2JvcgRIKXXTY0gCr06gWJOnAQEC" +
    "WCBQ2PNon5XpXDC+MtxOUWRg3/E5wIirERevDBBBiCUpSQNYIFX5OWOwg/Gr64K96b24+hB/qLT+c4Uvye5QQhWXxLx+BFggERER" +
    "EREREREREREREREREREREREREREREREREREREREFAQYCB1ggAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABYQKx/Q630" +
    "OY7rHQk3ST2uIS109LK1vlgwlkFnK93jrYJUNPw15Q6UA1DGeiIo4bV/LCobqyG5NtyAzViv5KaK39k="
    )!
  )
  static let second = FirstUploadWireSample(
    id: "93600000-0000-4000-8000-000000000932",
    hex:
    "d2845839a301382e0378286170706c69636174696f6e2f766e642e6c6576617261632e6f62736572766174696f6e2b63626f" +
    "7204485ef036280edf16eba0590117a801010250936000000000400080000000000009320378196c6576617261632e6d7574" +
    "75616c2d73656e73696e672f7631045820111111111111111111111111111111111111111111111111111111111111111105" +
    "58210279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798061a69c485d8075101aaaaaaaaaaaa" +
    "aaaaaaaaaaaaaaaaaaaa085883a5015820222222222222222222222222222222222222222222222222222222222222222202" +
    "0703835101000000000000000000000000000000015101000000000000000000000000000000025101000000000000000000" +
    "0000000000000304f60558205c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c58407d965e06" +
    "9fec40f48483fea2f92941686cfd87a7eebde3c7a58deedb0296e7c801dbdda9bce9112f817af021a6a680c921c586889b22" +
    "de81c75a49906e08066e",
    receipt: Data(base64Encoded:
    "0oRYQKMBOC4DeC9hcHBsaWNhdGlvbi92bmQubGV2YXJhYy5hY2NlcHRhbmNlLXJlY2VpcHQrY2JvcgRIKXXTY0gCr06gWJOnAQEC" +
    "WCBQ2PNon5XpXDC+MtxOUWRg3/E5wIirERevDBBBiCUpSQNYIFIC20Y8hArLe3ec1s6vEu0RyYPQGmu6wMeMg6lbqUlHBFggERER" +
    "EREREREREREREREREREREREREREREREREREREREFAQYCB1ggAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABYQJb9NfFW" +
    "+JpRyZg3oNJVENS3aKMjifXhBQtdN9tKPGfCAqOqFBsFQFM1MRGIsnn2bBTzRMQ1mTKtZM8tDZ9UVoY="
    )!
  )
}
