// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Foundation
import XCTest

/// Source-level release checks also run as a host XCTest executable, without
/// loading the app or a Simulator. Comments and internal identifiers alone
/// do not establish that obsolete user-facing copy is still in use.
final class ReleaseStringCatalogTests: XCTestCase {
  private var iosDirectory: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  }

  private func catalog() throws -> [String: Any] {
    let data = try Data(contentsOf: iosDirectory.appendingPathComponent("Beid/Localizable.xcstrings"))
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try XCTUnwrap(root["strings"] as? [String: Any])
  }

  func testCatalogContainsNoUnreferencedBannedCopy() throws {
    let appDirectory = iosDirectory.appendingPathComponent("Beid")
    let files = try XCTUnwrap(FileManager.default.enumerator(at: appDirectory, includingPropertiesForKeys: nil))
    let sources = try files.compactMap { $0 as? URL }
      .filter { $0.pathExtension == "swift" }
      .map { try String(contentsOf: $0, encoding: .utf8) }
      .joined(separator: "\n")
    let banned = try NSRegularExpression(
      pattern: "\\b(proofs?|proves?|automatically|no taps|NFT|token|on-chain|gas|mint|airdrop|web3)\\b",
      options: .caseInsensitive
    )
    for (key, entry) in try catalog() {
      let copy = ([key] + stringValues(in: entry)).joined(separator: " ")
      guard banned.firstMatch(in: copy, range: NSRange(copy.startIndex..., in: copy)) != nil else { continue }
      let literal = key.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
      XCTAssertTrue(sources.contains("\"\(literal)\""), "Unused banned catalog copy: \(key)")
    }
  }

  func testAccountWalletCopyIsRemovedFromCatalog() throws {
    let strings = try catalog()
    for key in [
      "Copied", "Copied address", "Copy address", "Disconnect", "Disconnect wallet", "Disconnect wallet?",
      "Keep connected", "Your records stay on this phone. Nothing is deleted.", "account.wallet.header"
    ] {
      XCTAssertNil(strings[key], key)
    }
  }

  private func stringValues(in value: Any) -> [String] {
    if let dictionary = value as? [String: Any] {
      return dictionary.flatMap { key, value in
        key == "value" ? (value as? String).map { [$0] } ?? [] : stringValues(in: value)
      }
    }
    if let array = value as? [Any] { return array.flatMap { stringValues(in: $0) } }
    return []
  }
}
