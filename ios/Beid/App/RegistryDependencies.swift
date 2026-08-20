// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BeidSharedKit
import Foundation

/// App-owned composition only; the registry package itself has no beid dependency.
enum RegistryDependencies {
  static func createClient(
    bundle: Bundle = .main
  ) -> ExportedKotlinPackages.org.levarac.parallax.registry.RegistryClient? {
    let readerAddress = bundle.object(
      forInfoDictionaryKey: "BeidEventRegistryReaderAddress"
    ) as? String ?? ""
    guard !readerAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    let apiKey = bundle.object(forInfoDictionaryKey: "BeidEtherscanAPIKey") as? String
    let nonEmptyApiKey = apiKey?.isEmpty == false ? apiKey : nil
    return ExportedKotlinPackages.org.levarac.parallax.registry.createSepoliaRegistryClient(
      readerAddressHex: readerAddress,
      etherscanApiKey: nonEmptyApiKey
    )
  }
}
