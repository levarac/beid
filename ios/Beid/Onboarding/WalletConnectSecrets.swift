// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation

/// Reads the Reown Cloud project ID from the gitignored `Beid/Secrets.plist`
/// (copy `ios/Secrets.example.plist` and fill in `PROJECT_ID` — see
/// ios/README.md "WalletConnect (spike)"). Returns nil when the file is
/// absent or the key is empty, so the app still builds, tests, and runs
/// without Ken-side credentials; the real WalletConnect path just reports
/// itself as not configured instead of crashing.
enum WalletConnectSecrets {
  static var projectId: String? {
    guard
      let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
      let data = try? Data(contentsOf: url),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
      let projectId = plist["PROJECT_ID"] as? String,
      !projectId.isEmpty
    else {
      return nil
    }
    return projectId
  }
}
