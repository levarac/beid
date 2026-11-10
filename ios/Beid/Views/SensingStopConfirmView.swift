// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import SwiftUI

/// Identity held while sensing continues. A record ID may not exist yet
/// when the participant requests a stop during initial detection.
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
          Text("Your record will be saved on this phone. You can join this event again later.")
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
            "KEEP SENSING",
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
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let elapsed = max(0, Int(sensing.firstSightingAt.map {
        sensing.sensingPresentationNow(context.date).timeIntervalSince($0)
      } ?? 0))
      let items = [
        SensingMetric(value: String(sensing.devicesVerified), label: "DEVICES HEARD"),
        SensingMetric(value: "\(elapsed / 60):\(String(format: "%02d", elapsed % 60))", label: "ELAPSED")
      ]
      HStack(alignment: .top, spacing: 0) {
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
    }
  }
}
