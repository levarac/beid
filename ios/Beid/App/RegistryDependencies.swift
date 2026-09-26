// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import BeidSharedKit
import Foundation

/// App-owned composition only; the registry package itself has no beid dependency.
enum RegistryDependencies {
  static func venueBundleURLTemplate(bundle: Bundle = .main) -> String? {
    guard let value = bundle.object(forInfoDictionaryKey: "BeidVenueBundleURLTemplate") as? String,
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return value
  }

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
    let definitionTemplate = bundle.object(
      forInfoDictionaryKey: "BeidEventDefinitionURLTemplate"
    ) as? String
    let nonEmptyDefinitionTemplate = definitionTemplate?.isEmpty == false
      ? definitionTemplate
      : nil
    let eventKeySetURLTemplate = bundle.object(
      forInfoDictionaryKey: "BeidEventKeySetURLTemplate"
    ) as? String
    let nonEmptyEventKeySetURLTemplate = eventKeySetURLTemplate?.isEmpty == false
      ? eventKeySetURLTemplate
      : nil
    let eventCodeLookupURLTemplate = bundle.object(
      forInfoDictionaryKey: "BeidEventCodeLookupURLTemplate"
    ) as? String
    let nonEmptyEventCodeLookupURLTemplate = eventCodeLookupURLTemplate?.isEmpty == false
      ? eventCodeLookupURLTemplate
      : nil
    let eventCodeHashLookupURLTemplate = bundle.object(
      forInfoDictionaryKey: "BeidEventCodeHashLookupURLTemplate"
    ) as? String
    let nonEmptyEventCodeHashLookupURLTemplate = eventCodeHashLookupURLTemplate?.isEmpty == false
      ? eventCodeHashLookupURLTemplate : nil
    return ExportedKotlinPackages.org.levarac.parallax.registry.createSepoliaRegistryClient(
      readerAddressHex: readerAddress,
      etherscanApiKey: nonEmptyApiKey,
      definitionUrlTemplate: nonEmptyDefinitionTemplate,
      eventKeySetUrlTemplate: nonEmptyEventKeySetURLTemplate,
      eventCodeLookupUrlTemplate: nonEmptyEventCodeLookupURLTemplate,
      eventCodeHashLookupUrlTemplate: nonEmptyEventCodeHashLookupURLTemplate
    )
  }
}
