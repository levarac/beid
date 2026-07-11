// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation
import WalletConnectSign // re-exports WalletConnectSigner's CryptoProvider

/// Minimal `CryptoProvider` to satisfy `Sign.configure(crypto:)`. Both
/// methods are only exercised by SIWE (`Sign.instance.authenticate`), which
/// beid's plain `connect(namespaces:)` pairing flow never calls — beid does
/// WalletConnect login, not SIWE. Left unimplemented rather than pulling in
/// Web3/CryptoSwift/HDWalletKit (as reown's own example app does) to satisfy
/// a code path this app doesn't use.
struct NativeCryptoProvider: CryptoProvider {
  func recoverPubKey(signature: EthereumSignature, message: Data) throws -> Data {
    fatalError("NativeCryptoProvider.recoverPubKey not implemented — SIWE authentication is out of scope for beid")
  }

  func keccak256(_ data: Data) -> Data {
    fatalError("NativeCryptoProvider.keccak256 not implemented — SIWE authentication is out of scope for beid")
  }
}
