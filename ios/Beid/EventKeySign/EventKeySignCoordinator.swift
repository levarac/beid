// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BarnardCore
import BeidSharedKit
import CryptoKit
import Foundation
import os

/// Native half of the event-key signing entry point.
///
/// `BeidSharedKit.eventkeysign` decides whether a `beid://event-key-sign` link
/// is acceptable and which bytes are signed. This type does the platform
/// part: bind the link's Event ID to an event this phone actually recorded,
/// ask the participant, sign through the same Barnard key owner that signs
/// observations, check the signature recovers to that key, and open the
/// callback compiled in for the purpose. The result never goes anywhere a
/// link names, and nothing is signed without an explicit tap.
@MainActor
final class EventKeySignCoordinator: ObservableObject {
  enum Purpose: Equatable {
    case personhoodBinding
    case claim(chainId: String, contract: String, recipient: String)
  }

  struct Pending: Identifiable, Equatable {
    let id = UUID()
    let purpose: Purpose
    let eventTitle: String
    let callbackHost: String

    fileprivate let eventCode: String
    fileprivate let eventKey: Data
    fileprivate let message: Data
    fileprivate let state: String
    fileprivate let callback: URL
  }

  enum Failure: Equatable, Identifiable {
    case eventNotOnThisPhone
    case keyMismatch
    case unavailable

    var id: Self { self }
  }

  /// The two https callbacks, one per purpose, read from the app's build
  /// settings. A missing or non-https value leaves that purpose disabled.
  struct Callbacks: Equatable {
    let personhoodBinding: URL?
    let claim: URL?

    static func fromBundle(_ bundle: Bundle = .main) -> Callbacks {
      Callbacks(
        personhoodBinding: validated(bundle.object(forInfoDictionaryKey: "BeidEventKeySignPersonhoodCallbackURL")),
        claim: validated(bundle.object(forInfoDictionaryKey: "BeidEventKeySignClaimCallbackURL"))
      )
    }

    static func validated(_ value: Any?) -> URL? {
      guard
        let string = value as? String,
        let components = URLComponents(string: string),
        components.scheme == "https",
        components.host?.isEmpty == false,
        components.user == nil,
        components.password == nil,
        components.fragment == nil,
        let url = components.url
      else { return nil }
      return url
    }
  }

  @Published private(set) var pending: Pending?
  @Published var failure: Failure?

  private static let log = Logger(subsystem: "org.levarac.beid", category: "EventKeySign")

  private let resolveEvent: (String) -> (eventCode: String, displayName: String?)?
  private let cryptography: () -> any SensingCryptography
  private let callbacks: Callbacks
  private let openURL: (URL) -> Void

  init(
    resolveEvent: @escaping (String) -> (eventCode: String, displayName: String?)?,
    cryptography: @escaping () -> any SensingCryptography,
    callbacks: Callbacks = .fromBundle(),
    openURL: @escaping (URL) -> Void
  ) {
    self.resolveEvent = resolveEvent
    self.cryptography = cryptography
    self.callbacks = callbacks
    self.openURL = openURL
  }

  /// Returns `true` for every `beid://event-key-sign` link, handled or
  /// refused, so the caller does not pass it on to the wallet connector.
  func handle(url: URL) -> Bool {
    guard url.scheme?.lowercased() == "beid", url.host == "event-key-sign" else { return false }
    // One request at a time: a second link cannot replace the one the
    // participant is reading.
    guard pending == nil else { return true }

    let parsed = BeidSharedKit.eventkeysign.parseEventKeySignLink(link: url.absoluteString)
    guard let accepted = parsed as? BeidSharedKit.eventkeysign.EventKeySignParseResult.Accepted else {
      Self.log.error("Refused an event-key signing link that did not parse")
      return true
    }
    let request = accepted.request

    let purpose: Purpose
    let callback: URL?
    switch request.purpose {
    case .PERSONHOOD_BINDING:
      purpose = .personhoodBinding
      callback = callbacks.personhoodBinding
    case .CLAIM:
      guard
        let chainId = request.chainIdDecimal,
        let contract = request.claimContractHex,
        let recipient = request.recipientHex
      else { return refuse(.unavailable) }
      purpose = .claim(chainId: chainId, contract: contract, recipient: recipient)
      callback = callbacks.claim
    default:
      return refuse(.unavailable)
    }
    guard let callback, let callbackHost = callback.host else { return refuse(.unavailable) }

    guard let event = resolveEvent(request.eventIdHex) else { return refuse(.eventNotOnThisPhone) }
    let eventKey = cryptography().eventSigningPublicKey(eventCode: event.eventCode)
    if let expected = request.expectedEventKeyHex, expected != eventKey.eventKeySignHex {
      return refuse(.keyMismatch)
    }
    guard let message = Data(eventKeySignHex: request.messageHex()) else { return refuse(.unavailable) }

    pending = Pending(
      purpose: purpose,
      eventTitle: event.displayName ?? "Event \(request.eventIdHex.prefix(8))",
      callbackHost: callbackHost,
      eventCode: event.eventCode,
      eventKey: eventKey,
      message: message,
      state: request.state,
      callback: callback
    )
    return true
  }

  /// Signs the pending message and hands the result to its callback. The
  /// signature is recovered and compared with the event key first, so a page
  /// never receives a signature that would not verify.
  func approve() {
    guard let request = pending else { return }
    pending = nil

    let signature = cryptography().signWindowReport(eventCode: request.eventCode, bytes: request.message)
    let digest = [UInt8](SHA256.hash(data: request.message))
    guard
      signature.v == 0 || signature.v == 1,
      let recovered = BarnardCoreSigning.recoverPublicKey(
        recoveryId: signature.v,
        r: [UInt8](signature.r),
        s: [UInt8](signature.s),
        messageHash32: digest
      ),
      recovered == [UInt8](request.eventKey),
      let address = BarnardCoreSigning.ethereumAddress(publicKeyCompressed: [UInt8](request.eventKey)),
      let fragment = BeidSharedKit.eventkeysign.eventKeySignSuccessFragment(
        state: request.state,
        rHex: signature.r.eventKeySignHex,
        sHex: signature.s.eventKeySignHex,
        recoveryId: Int32(signature.v),
        eventKeyHex: request.eventKey.eventKeySignHex,
        eventKeyAddressHex: "0x" + Data(address).eventKeySignHex
      ),
      let url = URL(string: request.callback.absoluteString + "#" + fragment)
    else {
      Self.log.error("Event-key signature did not recover to the event key; nothing was returned")
      failure = .unavailable
      return
    }
    openURL(url)
  }

  /// Tells the page the participant declined, without signing anything.
  func decline() {
    guard let request = pending else { return }
    pending = nil
    guard
      let fragment = BeidSharedKit.eventkeysign.eventKeySignCancelledFragment(state: request.state),
      let url = URL(string: request.callback.absoluteString + "#" + fragment)
    else { return }
    openURL(url)
  }

  private func refuse(_ reason: Failure) -> Bool {
    Self.log.error("Refused an event-key signing request")
    failure = reason
    return true
  }
}

private extension Data {
  init?(eventKeySignHex hex: String) {
    guard hex.count.isMultiple(of: 2) else { return nil }
    var bytes = [UInt8]()
    bytes.reserveCapacity(hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
      bytes.append(byte)
      index = next
    }
    self.init(bytes)
  }

  var eventKeySignHex: String {
    map { String(format: "%02x", $0) }.joined()
  }
}
