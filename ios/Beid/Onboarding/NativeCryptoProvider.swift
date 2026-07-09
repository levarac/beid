// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation
import WalletConnectSign // re-exports WalletConnectSigner's CryptoProvider

/// Minimal `CryptoProvider` to satisfy `Sign.configure(crypto:)`. Both
/// methods are only exercised by SIWE (`Sign.instance.authenticate`), which
/// this spike's plain `connect(requiredNamespaces:)` pairing flow never
/// calls into. Left unimplemented rather than pulling in Web3/CryptoSwift/
/// HDWalletKit (as reown's own example app does) to satisfy a code path
/// this spike doesn't use — see ios/README.md "WalletConnect (spike)".
struct NativeCryptoProvider: CryptoProvider {
  func recoverPubKey(signature: EthereumSignature, message: Data) throws -> Data {
    fatalError("NativeCryptoProvider.recoverPubKey not implemented — SIWE authentication is out of scope for this spike")
  }

  func keccak256(_ data: Data) -> Data {
    fatalError("NativeCryptoProvider.keccak256 not implemented — SIWE authentication is out of scope for this spike")
  }
}
