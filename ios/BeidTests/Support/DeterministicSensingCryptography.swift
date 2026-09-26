// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Foundation
@testable import Beid

/// Fast test double for sensing behavior tests that do not own secp256k1 correctness.
final class DeterministicSensingCryptography: SensingCryptography {
  enum Call: Equatable {
    case eventSigningPublicKey(eventCode: String)
    case ownerPublicKey
    case signWindowReport(eventCode: String, bytes: Data)
    case signSelfProof(
      eventIdHash: Data,
      eventSigningPublicKey: Data,
      eninStart: UInt64,
      eninEnd: UInt64
    )
    case signWalletAcknowledgement(walletAddress: Data, walletSignature: Data)
  }

  let eventSigningPublicKeyResult: Data
  let ownerPublicKeyResult: Data
  let windowReportSignatureResult: SensingRecoverableSignature
  let selfProofSignatureResult: SensingRecoverableSignature?
  /// `var`, unlike this type's other injected results: beid#316 needs
  /// exactly one caller (`SensingCryptographyTests
  /// .testCoordinatorRoutesBindingAndSelfProofCryptographyThroughInjectedFacade`)
  /// to overwrite this after construction but before `completeBinding` runs
  /// — the real acknowledgement it needs to inject depends on a wallet
  /// signature only known once `beginBinding` has already returned a
  /// message embedding a runtime nonce/timestamp, so it cannot be supplied
  /// through `init` like every other result here. The default value and
  /// every other test's usage are unaffected.
  var walletAcknowledgementSignatureResult: SensingRecoverableSignature?
  var walletAcknowledgementError: Error?
  var ownerPublicKeyError: Error?
  var selfProofError: Error?
  private(set) var calls: [Call] = []

  init(
    eventSigningPublicKey: Data = Data([0x02] + [UInt8](repeating: 0x33, count: 32)),
    ownerPublicKey: Data = Data([0x03] + [UInt8](repeating: 0x44, count: 32)),
    windowReportSignature: SensingRecoverableSignature = SensingRecoverableSignature(
      r: Data(repeating: 0x11, count: 32),
      s: Data(repeating: 0x22, count: 32),
      v: 0
    ),
    selfProofSignature: SensingRecoverableSignature? = SensingRecoverableSignature(
      r: Data(repeating: 0x55, count: 32),
      s: Data(repeating: 0x66, count: 32),
      v: 1
    ),
    walletAcknowledgementSignature: SensingRecoverableSignature? = SensingRecoverableSignature(
      r: Data(repeating: 0x77, count: 32),
      s: Data(repeating: 0x88, count: 32),
      v: 0
    )
  ) {
    eventSigningPublicKeyResult = eventSigningPublicKey
    ownerPublicKeyResult = ownerPublicKey
    windowReportSignatureResult = windowReportSignature
    selfProofSignatureResult = selfProofSignature
    walletAcknowledgementSignatureResult = walletAcknowledgementSignature
    walletAcknowledgementError = nil
    ownerPublicKeyError = nil
    selfProofError = nil
  }

  func eventSigningPublicKey(eventCode: String) -> Data {
    calls.append(.eventSigningPublicKey(eventCode: eventCode))
    return eventSigningPublicKeyResult
  }

  func ownerPublicKey() throws -> Data {
    calls.append(.ownerPublicKey)
    if let ownerPublicKeyError { throw ownerPublicKeyError }
    return ownerPublicKeyResult
  }

  func signWindowReport(eventCode: String, bytes: Data) -> SensingRecoverableSignature {
    calls.append(.signWindowReport(eventCode: eventCode, bytes: bytes))
    return windowReportSignatureResult
  }

  func signSelfProof(
    eventIdHash: Data,
    eventSigningPublicKey: Data,
    eninStart: UInt64,
    eninEnd: UInt64
  ) throws -> SensingRecoverableSignature? {
    calls.append(.signSelfProof(
      eventIdHash: eventIdHash,
      eventSigningPublicKey: eventSigningPublicKey,
      eninStart: eninStart,
      eninEnd: eninEnd
    ))
    if let selfProofError { throw selfProofError }
    return selfProofSignatureResult
  }

  func signWalletAcknowledgement(
    walletAddress: Data,
    walletSignature: Data
  ) throws -> SensingRecoverableSignature? {
    calls.append(.signWalletAcknowledgement(
      walletAddress: walletAddress,
      walletSignature: walletSignature
    ))
    if let walletAcknowledgementError { throw walletAcknowledgementError }
    return walletAcknowledgementSignatureResult
  }
}
