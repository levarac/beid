// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import SwiftUI

/// Identity held while the live coordinator continues sensing. `proofID` is
/// nil only in the gated screenshot fixture.
struct SensingStopConfirmSnapshot {
  let proofID: UUID?
  let event: EventSession
}

struct SensingStopConfirmView: View {
  @ObservedObject var sensing: SensingCoordinator
  let snapshot: SensingStopConfirmSnapshot
  let onStop: () -> Void
  let onKeepSensing: () -> Void

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          Text(verbatim: snapshot.event.name)
            .beidTextStyle(DS.Font.Library.display46)
            .foregroundStyle(DS.Color.labelOnActionPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 220, alignment: .leading)
            .accessibilityAddTraits(.isHeader)

          if let eventDetail {
            Text(verbatim: eventDetail)
              .beidTextStyle(DS.Font.Library.body15)
              .foregroundStyle(DS.Color.textSecondaryOnInk)
              .padding(.top, DS.Space.s)
          }

          Spacer(minLength: DS.Space.xxl)

          Text("Stop sensing?")
            .beidTextStyle(DS.Font.Library.title19)
            .foregroundStyle(DS.Color.labelOnActionPrimary)
          Text("Stop sensing to seal and keep what you've recorded on this phone. You can sense this event again later.")
            .beidTextStyle(DS.Font.Library.body15)
            .foregroundStyle(DS.Color.textSecondaryOnInk)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, DS.Space.s)

          Text("SO FAR")
            .beidTextStyle(DS.Font.Library.labelMono10)
            .foregroundStyle(DS.Color.textSecondaryOnInk)
            .padding(.top, DS.Space.xxl)

          metrics
            .padding(.top, DS.Space.s)

          Spacer(minLength: DS.Space.xxl)

          Button {
            BeidDesign.haptic()
            onStop()
          } label: {
            Text("Stop and keep record")
              .beidTextStyle(DS.Font.Library.title16)
              .foregroundStyle(DS.Color.labelOnActionInverse)
              .frame(maxWidth: .infinity)
              .frame(minHeight: DS.Size.primaryButtonMinHeight)
              .background(DS.Color.actionInverse, in: Capsule())
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("scan.stop-confirm.stop")

          BeidTextControl(
            "Keep sensing",
            labelColor: DS.Color.labelOnActionPrimary,
            accessibilityLabel: "Keep sensing",
            action: onKeepSensing
          )
            .frame(maxWidth: .infinity)
            .padding(.top, DS.Space.l)
            .padding(.bottom, DS.Space.xl)
        }
        .frame(minHeight: geometry.size.height, alignment: .top)
        .padding(.horizontal, DS.Space.pageMargin)
      }
    }
    .background(DS.Color.textPrimary.ignoresSafeArea())
    .accessibilityIdentifier("scan.stop-confirm")
  }

  private var eventDetail: String? {
    var parts: [String] = []
    if let venue = snapshot.event.venue, !venue.isEmpty { parts.append(venue) }
    if let firstSightingAt = sensing.firstSightingAt {
      parts.append("since \(firstSightingAt.formatted(date: .omitted, time: .shortened))")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private var metrics: some View {
    let items = [
      SensingMetric(value: String(sensing.sessionAggregate?.mutualDeviceCount ?? 0), label: "MUTUAL"),
      SensingMetric(value: String(sensing.devicesVerified), label: "DETECTED"),
      SensingMetric(value: String(sensing.sessionAggregate?.windowCount ?? 0), label: "WINDOWS")
    ]
    return HStack(alignment: .top, spacing: 0) {
      ForEach(items) { item in
        VStack(alignment: .leading, spacing: DS.Space.xs) {
          Text(verbatim: item.value)
            .beidTextStyle(DS.Font.Library.displayNumber40)
            .foregroundStyle(DS.Color.labelOnActionPrimary)
          Text(verbatim: item.label)
            .beidTextStyle(DS.Font.Library.labelMono10)
            .foregroundStyle(DS.Color.textSecondaryOnInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "\(sensing.sessionAggregate?.mutualDeviceCount ?? 0) mutual, "
        + "\(sensing.devicesVerified) detected, "
        + "window \(sensing.sessionAggregate?.windowCount ?? 0)"
    )
  }
}
