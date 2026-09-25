// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// gh#138 — venue-device organizer sub-screen, pushed from `AccountSheetView`
/// via `NavigationLink` (`docs/specs/participation-surface.md` §5.3: a
/// sub-screen off the existing Account Sheet, using local state rather than
/// routing through `AppCoordinator`). Sets a label (bound to Barnard's B005
/// `eventDisplayName`) and a local validity period, then turns B005 serving
/// on/off via `VenueDeviceOrganizerViewModel`. Read-only reassignment history
/// underneath, per §5.4.
///
/// Binds to whatever event `sensingCoordinator.joinedEventCode` already
/// names — the venue-device engine and the participation engine are
/// separate `BarnardEngine` instances (see `VenueDeviceBroadcasting`'s doc
/// comment), but B005's payload is only ever meaningful for an event this
/// device actually has the code for, so broadcasting requires having joined
/// one first.
struct VenueDeviceOrganizerView: View {
  @ObservedObject var sensingCoordinator: SensingCoordinator
  @StateObject private var viewModel: VenueDeviceOrganizerViewModel

  init(sensingCoordinator: SensingCoordinator) {
    self.sensingCoordinator = sensingCoordinator
    _viewModel = StateObject(wrappedValue: VenueDeviceOrganizerViewModel())
  }

  var body: some View {
    List {
      Section {
        VStack(alignment: .leading, spacing: DS.Space.s) {
          TextField("Label", text: $viewModel.label, prompt: Text("e.g. Doorway A"))
            .font(DS.Font.body)
            .foregroundStyle(DS.Color.textPrimary)
            .disabled(viewModel.isBroadcasting)
            .accessibilityIdentifier("Venue device label")
        }

        DatePicker(
          "Starts",
          selection: $viewModel.validityStart,
          displayedComponents: [.date, .hourAndMinute]
        )
        .disabled(viewModel.isBroadcasting)

        DatePicker(
          "Ends",
          selection: $viewModel.validityEnd,
          displayedComponents: [.date, .hourAndMinute]
        )
        .disabled(viewModel.isBroadcasting)

        if let validationError = viewModel.validationError {
          HStack(alignment: .top, spacing: DS.Space.s) {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(DS.Color.textPrimary)
              .accessibilityHidden(true)
            Text(message(for: validationError))
              .font(DS.Font.supporting)
              .foregroundStyle(DS.Color.textPrimary)
          }
        }
      } header: {
        Text("Assignment")
      } footer: {
        // PM-approved exact copy (docs/specs/participation-surface.md §3.2,
        // ruled 2026-08-09) — organizer-side trust disclaimer, verbatim.
        // Never edit this string without a new PM sign-off.
        Text(
          "Beid does not verify this broadcast. Anyone nearby with the app can see the name you set here.",
          comment: """
          Organizer-facing trust disclaimer shown under the label field on \
          the venue-device screen. "This broadcast" refers to the Bluetooth \
          broadcast this screen's toggle turns on, not the app itself. "The \
          name you set here" refers to the Label field on this same screen.
          """
        )
      }

      Section {
        Toggle(isOn: broadcastingBinding) {
          HStack(spacing: DS.Space.m) {
            Circle()
              .fill(viewModel.isBroadcasting ? DS.Color.statusOn : DS.Color.statusOff)
              .frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
              .accessibilityHidden(true)
            Text("Broadcasting")
          }
        }
        .tint(DS.Color.actionPrimary)
      }

      Section {
        if viewModel.history.isEmpty {
          Text("No assignments yet.")
            .font(DS.Font.supporting)
            .foregroundStyle(DS.Color.textSecondary)
        } else {
          ForEach(viewModel.history) { record in
            VStack(alignment: .leading, spacing: DS.Space.xs) {
              HStack {
                Text(record.label)
                  .font(DS.Font.cardTitle)
                  .foregroundStyle(DS.Color.textPrimary)
                if viewModel.isBroadcasting, record.id == viewModel.history.first?.id {
                  Text("Active")
                    .font(DS.Font.meta)
                    .foregroundStyle(DS.Color.textPrimary)
                }
              }
              Text(validityRangeText(for: record))
                .font(DS.Font.meta)
                .foregroundStyle(DS.Color.textSecondary)
              Text(assignedAtText(for: record))
                .font(DS.Font.meta)
                .foregroundStyle(DS.Color.textSecondary)
            }
          }
        }
      } header: {
        Text("History")
      }
    }
    .scrollContentBackground(.hidden)
    .background(DS.Color.surfaceCanvas)
    .navigationTitle("Venue Device")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var broadcastingBinding: Binding<Bool> {
    Binding(
      get: { viewModel.isBroadcasting },
      set: { isOn in
        BeidDesign.haptic()
        if isOn {
          viewModel.toggleOn(eventCode: sensingCoordinator.joinedEventCode)
        } else {
          viewModel.toggleOff()
        }
      }
    )
  }

  private func message(for error: VenueDeviceValidationError) -> LocalizedStringKey {
    switch error {
    case .noJoinedEvent:
      return "Join an event first, then come back to set up this device."
    case .missingLabel:
      return "Enter a label to identify this device."
    case .invalidLabel:
      return "That label isn't valid. Try a shorter name using regular text."
    case .validityPeriodOutOfOrder:
      return "End time must be after the start time."
    }
  }

  private func validityRangeText(for record: VenueDeviceAssignmentRecord) -> String {
    let start = record.validityStart.formatted(date: .abbreviated, time: .shortened)
    let end = record.validityEnd.formatted(date: .abbreviated, time: .shortened)
    return String(
      localized: "venueDevice.history.validityRange",
      defaultValue: "Valid \(start) – \(end)"
    )
  }

  private func assignedAtText(for record: VenueDeviceAssignmentRecord) -> String {
    let assignedAt = record.assignedAt.formatted(date: .abbreviated, time: .shortened)
    return String(
      localized: "venueDevice.history.assignedAt",
      defaultValue: "Assigned \(assignedAt)"
    )
  }
}

#Preview {
  NavigationStack {
    VenueDeviceOrganizerView(sensingCoordinator: SensingCoordinator())
  }
}
