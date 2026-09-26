// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import Combine
import SwiftUI

/// What screen 14's Saved pack area says about the pack stored on this device
/// (beid#702).
///
/// Every case is a fact this device measured about its own storage, never a
/// verification verdict. By the time 14 is on screen, 14b has ended its session
/// and cleared the radio, and nothing it verified was kept: the store holds
/// public bytes only, by rule. So there is deliberately no case for "checked",
/// "broadcasting", an event name, an event id or a validity period — 14 cannot
/// know any of them truthfully.
enum SavedPackRowState: Equatable {
  /// Nothing stored, and no stored file failed to load.
  case none
  /// A stored file exists that could not be read, whether it was set aside
  /// (quarantined) or left in place with writes suspended.
  case unreadable
  case saved(source: String, storedAt: Date)
  /// A pack is held in memory but did not reach disk (the 14g condition).
  case notSaved(source: String)

  /// Order is S3 → S2 → S1 → S0. `notSaved` is decided before `saved` because
  /// the store assigns `record` before it writes, so a failed write still has a
  /// record; checking `saved` first would claim a save that did not happen.
  static func resolve(
    record: VenuePublicArtifactRecord?,
    persistenceFailed: Bool,
    persistenceSuspended: Bool,
    quarantined: Bool
  ) -> SavedPackRowState {
    if let record, persistenceFailed || persistenceSuspended { return .notSaved(source: record.sourceDescription) }
    if let record { return .saved(source: record.sourceDescription, storedAt: record.storedAt) }
    if quarantined || persistenceSuspended { return .unreadable }
    return .none
  }
}

/// Screen 14's store and 14b's view model, created together so both read the
/// same `VenuePublicArtifactStore` instance.
///
/// Held by one `@StateObject`, whose autoclosure SwiftUI evaluates once per view
/// identity. The store's `init` reads — and on a decode failure quarantines —
/// its file, so it must not run on every re-init of the view struct, which a
/// `let` in the view's own `init` would do.
@MainActor
final class OrganizerToolsObjects: ObservableObject {
  let store: VenuePublicArtifactStore
  let serving: VenueSignedServingViewModel
  private var forwarding: [AnyCancellable] = []

  /// `makeServing` receives the store rather than capturing one, so the view
  /// model cannot be given a different instance from the one 14 reads.
  init(
    store: VenuePublicArtifactStore,
    makeServing: (VenuePublicArtifactStore) -> VenueSignedServingViewModel
  ) {
    self.store = store
    serving = makeServing(store)
    // 14 draws from both objects, and a nested ObservableObject does not
    // republish on its own.
    forwarding = [
      store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
      serving.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
    ]
  }

  /// The store file `production()` uses, fixed once per process: re-entering
  /// 14 within one launch reads the same file, not a new empty one. `nil` is
  /// the store's default location.
  private static let productionStoreURL: URL? = {
    #if DEBUG
    return storeURL(arguments: ProcessInfo.processInfo.arguments)
    #else
    return nil
    #endif
  }()

  /// Every UI-test launch starts from its own empty pack file, so no UI test
  /// reads a previous launch's pack or ever writes the real file. Each call
  /// names a new file; `productionStoreURL` is what pins one per launch.
  /// Release never reads the arguments and always uses the default location.
  nonisolated static func storeURL(arguments: [String]) -> URL? {
    #if DEBUG
    guard arguments.contains("-beid-ui-test") else { return nil }
    return FileManager.default.temporaryDirectory.appendingPathComponent(
      "beid-venue-public-artifact-\(UUID().uuidString).json"
    )
    #else
    return nil
    #endif
  }

  static func production() -> OrganizerToolsObjects {
    OrganizerToolsObjects(store: VenuePublicArtifactStore(fileURL: productionStoreURL)) { store in
      VenueSignedServingViewModel(
        verifier: ProductionVenueBundleVerifier(registryClient: RegistryDependencies.createClient()),
        broadcasting: BarnardVenueSignedContainerBroadcasting(),
        acquisition: VenueArtifactAcquisition(),
        store: store,
        clock: { VenueDeviceClock.read() }
      )
    }
  }

  /// Reads the store only. Nothing here fetches, verifies, writes or touches
  /// the radio.
  var savedPack: SavedPackRowState {
    SavedPackRowState.resolve(
      record: store.record,
      persistenceFailed: store.persistenceWriteFailure != nil,
      persistenceSuspended: store.isPersistenceSuspended,
      quarantined: store.quarantinedFileURL != nil
    )
  }
}

/// Flat 2b screen 14. #597 withdrew the unsigned Venue device entrance;
/// venue-key configuration has no app implementation — the venue device holds
/// no key (beid#432, beid#702). The single route here is the existing verified
/// pack import and signed broadcast workflow; the Saved pack area below it only
/// reports what is stored and has no controls.
struct OrganizerToolsView: View {
  @StateObject private var tools = OrganizerToolsObjects.production()
  @State private var showVenueBroadcast = false

  private var serving: VenueSignedServingViewModel { tools.serving }

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
        savedPackSection
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

  // MARK: - Saved pack (beid#702)

  /// Figma 14's `VENUE KEY` block, renamed for what it holds: a heading, a
  /// STATUS row and value rows. A row with no value is left out rather than
  /// shown empty.
  private var savedPackSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Saved pack")
        .beidTextStyle(DS.Font.Library.labelMono10)
        .foregroundStyle(DS.Color.textSecondary)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("organizer.savedPack.heading")
        .padding(.top, DS.Space.xl)
        .padding(.bottom, DS.Space.s)
      savedPackHairline
      savedPackRow("Status") {
        Text(savedPackStatusLabel)
          .beidTextStyle(DS.Font.Library.labelMono11)
          .accessibilityIdentifier("organizer.savedPack.status")
      }
      switch savedPack {
      case .saved(let source, let storedAt):
        sourceRow(source)
        savedPackRow("Saved") {
          Text(verbatim: storedAt.formatted(date: .abbreviated, time: .shortened))
            .beidTextStyle(DS.Font.Library.labelMono11Time)
            .accessibilityIdentifier("organizer.savedPack.storedAt")
        }
      case .notSaved(let source):
        sourceRow(source)
      case .unreadable, .none:
        EmptyView()
      }
      if let note = savedPackNote {
        Text(note)
          .beidTextStyle(DS.Font.Library.body13)
          .foregroundStyle(DS.Color.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("organizer.savedPack.note")
          .padding(.top, DS.Space.m)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("organizer.savedPack")
  }

  private func sourceRow(_ source: String) -> some View {
    savedPackRow("Source") {
      Text(verbatim: source)
        .beidTextStyle(DS.Font.Library.labelMono11Time)
        .accessibilityIdentifier("organizer.savedPack.source")
    }
  }

  /// The same key/value row 14b draws, without any control in it.
  private func savedPackRow<Value: View>(_ key: LocalizedStringKey, @ViewBuilder value: () -> Value) -> some View {
    VStack(spacing: 0) {
      HStack(alignment: .center, spacing: DS.Space.s) {
        Text(key)
          .beidTextStyle(DS.Font.Library.labelMono10)
          .foregroundStyle(DS.Color.textSecondary)
        Spacer(minLength: DS.Space.s)
        value()
          .foregroundStyle(DS.Color.textPrimary)
          .multilineTextAlignment(.trailing)
      }
      .frame(minHeight: DS.Size.keyValueRowMinHeight)
      savedPackHairline
    }
  }

  private var savedPackHairline: some View {
    Rectangle().fill(DS.Color.strokeHairline).frame(height: DS.Size.hairline)
  }

  private var savedPackStatusLabel: LocalizedStringKey {
    switch savedPack {
    case .notSaved: return "Not saved"
    case .saved: return "Saved on this device"
    case .unreadable: return "Could not read"
    case .none: return "No saved pack"
    }
  }

  private var savedPackNote: LocalizedStringKey? {
    switch savedPack {
    case .notSaved: return "This pack could not be saved. It stays on this device only until the app closes."
    case .saved: return "A saved pack is checked again every time it is loaded."
    case .unreadable: return "This pack could not be read."
    case .none: return nil
    }
  }

  private var savedPack: SavedPackRowState {
    savedPackFixture ?? tools.savedPack
  }

  // A display-only, two-argument Debug gate, the same shape as 14b's
  // `-beid-venue-frame`. It replaces what this area DRAWS and nothing else: it
  // writes no store file, and no fixture value reaches the view model, the
  // verifier, acquisition or the radio. No fixture is recognized in Release.
  private var savedPackFixture: SavedPackRowState? {
    #if DEBUG
    let arguments = ProcessInfo.processInfo.arguments
    guard arguments.contains("-beid-ui-test"),
      let index = arguments.firstIndex(of: "-beid-organizer-frame"),
      arguments.indices.contains(index + 1) else { return nil }
    let source = "link, bundle from organizer.eth"
    switch arguments[index + 1] {
    case "14-saved": return .saved(source: source, storedAt: Date(timeIntervalSince1970: 1_790_000_000))
    case "14-not-saved": return .notSaved(source: source)
    default: return nil
    }
    #else
    return nil
    #endif
  }
}
