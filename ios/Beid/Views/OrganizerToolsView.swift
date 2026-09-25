// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Flat 2b screen 14. #597 withdrew the unsigned Venue device entrance;
/// venue-key configuration has no app implementation. The single route here
/// is the existing verified pack import and signed broadcast workflow.
struct OrganizerToolsView: View {
  @StateObject private var serving = VenueSignedServingViewModel(
    verifier: ProductionVenueBundleVerifier(registryClient: RegistryDependencies.createClient()),
    broadcasting: BarnardVenueSignedContainerBroadcasting(),
    acquisition: VenueArtifactAcquisition(),
    store: VenuePublicArtifactStore(),
    clock: { VenueDeviceClock.read() }
  )
  @State private var showVenueBroadcast = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        Text("iOS only")
          .beidTextStyle(DS.Font.Library.labelMono10)
          .foregroundStyle(DS.Color.textSecondary)
          .padding(.bottom, DS.Space.s)
        Text("Organizer")
          .beidTextStyle(DS.Font.Library.display52)
          .foregroundStyle(DS.Color.textPrimary)
        Text("Tools for the venue side. Attendees never need these.")
          .beidTextStyle(DS.Font.Library.body15)
          .foregroundStyle(DS.Color.textSecondary)
          .padding(.top, DS.Space.m)
          .padding(.bottom, DS.Space.m)

        Rectangle()
          .fill(DS.Color.strokeHairline)
          .frame(height: DS.Size.hairline)
        Button {
          showVenueBroadcast = true
        } label: {
          HStack(alignment: .center, spacing: DS.Space.s) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
              Text("Venue broadcast")
                .beidTextStyle(DS.Font.Library.title17)
              Text("Load a signed pack, check it, then broadcast it.")
                .beidTextStyle(DS.Font.Library.body13)
                .foregroundStyle(DS.Color.textSecondary)
            }
            Spacer(minLength: DS.Space.s)
            Text(statusLabel)
              .beidTextStyle(DS.Font.Library.labelMono10)
              .foregroundStyle(DS.Color.textSecondary)
            Text(verbatim: "→")
              .beidTextStyle(DS.Font.Library.labelMono11)
              .accessibilityHidden(true)
          }
          .foregroundStyle(DS.Color.textPrimary)
          .frame(minHeight: DS.Size.listRowMinHeight)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Venue broadcast")
        .accessibilityValue(Text(statusLabel))
        .accessibilityIdentifier("organizer.venueBroadcast")
        Rectangle()
          .fill(DS.Color.strokeHairline)
          .frame(height: DS.Size.hairline)
      }
      .frame(maxWidth: DS.Layout.stateContentMaxWidth, alignment: .leading)
      .padding(.horizontal, DS.Space.pageMargin)
      .frame(maxWidth: .infinity)
    }
    .background(DS.Color.surfaceCanvas)
    .navigationBarTitleDisplayMode(.inline)
    .navigationDestination(isPresented: $showVenueBroadcast) {
      VenueSignedServingView(viewModel: serving)
        .accountLargeDetent(.venueBroadcast)
    }
    .toolbarBackground(DS.Color.surfaceCanvas, for: .navigationBar)
    .toolbarColorScheme(.light, for: .navigationBar)
  }

  private var statusLabel: LocalizedStringKey {
    if case .serving = serving.status { return "Asked to broadcast" }
    return "Not broadcasting"
  }
}
