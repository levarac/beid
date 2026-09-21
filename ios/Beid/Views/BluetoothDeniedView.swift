// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI
import UIKit

/// Screen 03: Bluetooth permission recovery. A denied permission must not
/// expose event cards; the only useful next step is the app's Settings page.
struct BluetoothDeniedView: View {
  @EnvironmentObject private var coordinator: AppCoordinator

  var body: some View {
    BeidStatusLayout(
      systemImage: "hand.raised.slash",
      title: "Bluetooth permission required",
      message: "This feature requires Bluetooth permission.",
      footer: {
        BeidPrimaryButton("Open Settings", systemImage: "gearshape") {
          UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
        }
      }
    )
  }
}

#Preview {
  BluetoothDeniedView().environmentObject(AppCoordinator())
}
