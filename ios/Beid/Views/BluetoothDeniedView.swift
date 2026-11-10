// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import SwiftUI
import UIKit

/// Screen 03: Bluetooth permission recovery. A denied permission must not
/// expose event cards; the only useful next step is the app's Settings page.
struct BluetoothDeniedView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  var body: some View {
    BeidStatusLayout(
      title: "beid needs Bluetooth",
      message: "beid uses Bluetooth to find nearby events and hear nearby phones. Turn it on for beid in Settings.",
      footer: {
        BeidPrimaryButton("Open Settings") {
          UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
        }
      }
    )
  }
}

#Preview {
  BluetoothDeniedView().environmentObject(AppCoordinator())
}
