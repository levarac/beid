// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import BeidSharedKit
import Foundation
import SwiftUI

/// Display-only projection of one shared nearby candidate.
///
/// `eventIdHex` is deliberately optional and appears only when the shared
/// eligibility decision says the candidate is currently joinable. The action
/// still carries only `eventCodeHashHex`; neither this ID nor either display
/// validity value is authority for a join.
struct NearbyEventCard: Identifiable, Equatable {
  let beaconDisplayName: String?
  let eventIdHex: String?
  let displayValidFromEpochSeconds: Int64?
  let displayValidUntilEpochSeconds: Int64?
  let eventCodeHashHex: String
  let hasDisplayNameConflict: Bool

  init(
    beaconDisplayName: String?,
    eventIdHex: String?,
    displayValidFromEpochSeconds: Int64?,
    displayValidUntilEpochSeconds: Int64?,
    eventCodeHashHex: String,
    hasDisplayNameConflict: Bool = false
  ) {
    self.beaconDisplayName = beaconDisplayName
    self.eventIdHex = eventIdHex
    self.displayValidFromEpochSeconds = displayValidFromEpochSeconds
    self.displayValidUntilEpochSeconds = displayValidUntilEpochSeconds
    self.eventCodeHashHex = eventCodeHashHex
    self.hasDisplayNameConflict = hasDisplayNameConflict
  }

  var id: String { eventCodeHashHex }

  /// The testable SwiftUI action contract: an enabled card forwards the
  /// stable candidate hash, never the displayed Event ID or list position.
  var joinActionEventCodeHashHex: String? {
    eventIdHex == nil ? nil : eventCodeHashHex
  }
}

/// Small presentation model shared by the live SwiftUI surface and focused
/// tests. It projects every candidate, but delegates enablement to shared.
struct NearbyEventCardListPresentation {
  let cards: [NearbyEventCard]
  let selectedEventCodeHashHex: String?

  /// Barnard kept 32 hashes and dropped the rest, and said so
  /// (`additionalEventsOmitted`). Carried to the view because **a silent
  /// absence reads as a legitimate empty case** — a participant looking at
  /// this list concludes "that is what is nearby", and it is not (beid#450).
  ///
  /// Never a count: the SDK does not say how many it dropped, and inventing a
  /// denominator would be the same class of defect one step along.
  let hasOmittedEvents: Bool

  init(cards: [NearbyEventCard], hasOmittedEvents: Bool = false) {
    self.cards = cards
    self.hasOmittedEvents = hasOmittedEvents
    let joinableCards = cards.filter { $0.eventIdHex != nil }
    selectedEventCodeHashHex = joinableCards.count == 1
      ? joinableCards[0].eventCodeHashHex
      : nil
  }

  init(
    candidates: ExportedKotlinPackages.org.levarac.parallax.discovery.NearbyEventCandidates,
    nowEpochSeconds: Int64
  ) {
    var projectedCards: [NearbyEventCard] = []
    for index in 0..<candidates.candidateCount {
      guard let candidate = candidates.candidateAt(index: index) else { continue }
      let verifiedJoin = ExportedKotlinPackages.org.levarac.parallax.discovery
        .RegistryVerifiedJoinContext.Companion.shared.fromNearbyCandidate(
          candidates: candidates,
          eventCodeHashHex: candidate.eventCodeHashHex,
          nowEpochSeconds: nowEpochSeconds
        )
      projectedCards.append(
        NearbyEventCard(
          beaconDisplayName: candidate.displayNameAt(index: 0),
          eventIdHex: verifiedJoin?.eventIdHex,
          displayValidFromEpochSeconds: verifiedJoin != nil
            ? candidate.definitionValidFromEpochSeconds
            : nil,
          displayValidUntilEpochSeconds: verifiedJoin != nil
            ? candidate.definitionValidUntilEpochSeconds
            : nil,
          eventCodeHashHex: candidate.eventCodeHashHex,
          hasDisplayNameConflict: candidate.hasDisplayNameConflict
        )
      )
    }
    self.init(
      cards: projectedCards,
      hasOmittedEvents: candidates.additionalEventsOmitted
    )
  }

  var isSearching: Bool { cards.isEmpty }
  var showsManualEntryRescue: Bool { true }
}

/// Screen 05: Scan screen with a radar animation, "Sensing automatically".
struct SensingView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ObservedObject private var sensing: SensingCoordinator
  /// beid#464. nil on preview paths, which have no preflight to show.
  private let clockPreflight: ClockPreflightController?
  @State private var pulse = false

  init(sensing: SensingCoordinator, clockPreflight: ClockPreflightController? = nil) {
    self.sensing = sensing
    self.clockPreflight = clockPreflight
  }

  var body: some View {
    ZStack {
      DS.Color.surfaceCanvas
        .ignoresSafeArea()

      ScrollView {
        BeidAdaptiveContent {
          VStack(spacing: BeidDesign.Spacing.section) {
            BeidStatusPill(state: .sensingAutomatically)

            radar

            Text("Walk into an event — it will show up here automatically.")
              .font(DS.Font.body)
              .foregroundStyle(DS.Color.textSecondary)
              .multilineTextAlignment(.center)
              .lineSpacing(2)
              .fixedSize(horizontal: false, vertical: true)

            if isPreJoin, let clockPreflight {
              ClockPreflightNoticeView(preflight: clockPreflight)
            }

            if let joinRefusalMessage {
              joinRefusalNotice(joinRefusalMessage)
            }

            if isPreJoin {
              nearbyEvents
            }
          }
          .frame(maxWidth: .infinity)
          .padding(.horizontal, BeidDesign.Spacing.screenHorizontal)
          .padding(.vertical, DS.Space.l)
        }
      }
    }
    // Sensing screen: DESIGN.md §5 "one motif accent per screen" — also
    // what the radar rings' `.tint.opacity(...)` and the center glyph's
    // default `.accentColor` resolve to.
    .tint(DS.Color.signalActive)
    .onAppear { pulse = !reduceMotion }
    .safeAreaInset(edge: .bottom) {
      if isPreJoin {
        BeidAdaptiveContent {
          NavigationLink {
            EventCodeEntryView(mode: .scanFlow)
          } label: {
            Text(manualEntryTitle)
              .font(DS.Font.cardTitle)
              .frame(maxWidth: .infinity, minHeight: DS.Size.minHitTarget)
          }
          .buttonStyle(.bordered)
          .buttonBorderShape(.roundedRectangle(radius: DS.Radius.control))
          .padding(.horizontal, DS.Space.pageMargin)
          .padding(.vertical, DS.Space.s)
          .accessibilityIdentifier("scan.manual-entry")
        }
        .background(.bar)
      }
    }
    .accessibilityIdentifier("scan.sensing")
  }

  private var isPreJoin: Bool {
    if case .idle = sensing.phase { return true }
    return false
  }

  private var nearbyPresentation: NearbyEventCardListPresentation {
    NearbyEventCardListPresentation(
      candidates: sensing.nearbyEventCandidates,
      nowEpochSeconds: Int64(Date().timeIntervalSince1970.rounded(.down))
    )
  }

  /// What to say about a refused join, or nil when nothing was refused.
  ///
  /// The reason is `shared/`'s (`eventJoinFailureReasonKey`); these sentences
  /// are this host's, and they are the same English Android already ships
  /// (`event_join_error_*`), so one situation does not read as two different
  /// products.
  ///
  /// Until beid#472 there was nothing here at all. `SensingCoordinator` held
  /// the refusal and no view read it, so a radio that never started looked
  /// exactly like one that had found nobody yet — including to the owner,
  /// during a field session on 2026-09-10.
  private var joinRefusalMessage: LocalizedStringKey? {
    guard let key = sensing.joinRefusalReasonKey else { return nil }
    switch key {
    case "network_required":
      return "beid needs a connection to verify this event, and couldn't reach the network. Check your connection and try again."
    case "event_not_found":
      return "No event is registered for that code. Check it with the event organizer."
    case "code_mismatch":
      return "That code didn't match the event beid found. Check that you have the whole code."
    case "event_not_active":
      return "That event isn't open to join right now."
    case "verification_failed":
      return "beid couldn't verify that event. Check the code with the event organizer."
    default:
      // A reason added in `shared/` without this switch being updated says
      // less rather than saying something false.
      return "beid couldn't join that event. Check the code and try again."
    }
  }

  /// DESIGN.md §15's error formula — what happened and one action — rendered
  /// in the non-signal caution register (§5: `statusCaution` is for errors
  /// that are not about BLE signal, which a refused join is not).
  /// One surface for one refusal.
  ///
  /// There were briefly two: this one, and a `BeidPanel` inside
  /// `nearbyEvents` reading "This event cannot be joined yet. / Check the
  /// event details and try again." They landed from different changes and
  /// both rendered, so a single refusal said two things — and the generic
  /// one told an offline participant to check a code that was correct, the
  /// exact false advice beid#472 set out to remove. The panel's container and
  /// its accessibility identifier are kept here; its copy is not.
  private func joinRefusalNotice(_ message: LocalizedStringKey) -> some View {
    BeidPanel {
      HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(DS.Color.statusCaution)
        Text(message)
          .font(DS.Font.supporting)
          .foregroundStyle(DS.Color.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("scan.join-refusal")
  }

  @ViewBuilder
  private var nearbyEvents: some View {
    let presentation = nearbyPresentation
    VStack(alignment: .leading, spacing: DS.Space.s) {
      Text("Nearby events")
        .font(DS.Font.sectionTitle)
        .foregroundStyle(DS.Color.textPrimary)

      if presentation.isSearching {
        BeidPanel {
          VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(searchingTitle)
              .font(DS.Font.cardTitle)
              .foregroundStyle(DS.Color.textPrimary)
            Text(rescueGuidance)
              .font(DS.Font.supporting)
              .foregroundStyle(DS.Color.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      } else {
        ForEach(presentation.cards) { card in
          nearbyEventCard(
            card,
            selected: card.eventCodeHashHex == presentation.selectedEventCodeHashHex
          )
        }
      }

      if presentation.hasOmittedEvents {
        omittedEventsRow
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier("scan.nearby-events")
  }

  /// Barnard kept 32 hashes and dropped the rest. Saying nothing would leave
  /// the list above reading as "this is what is nearby", which it is not.
  ///
  /// **Static, and deliberately without a number.** The SDK reports *that* it
  /// dropped events, never how many, so a count here would be invented —
  /// `docs/specs/event-discovery.md` §5.3 says append one static row rather
  /// than trying to read the omitted event's own payload, which by then
  /// carries an empty marker rather than a real hint (beid#450).
  private var omittedEventsRow: some View {
    Text("Some nearby events are not shown.")
      .font(DS.Font.meta)
      .foregroundStyle(DS.Color.textSecondary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityIdentifier("scan.nearby-events.omitted")
  }

  private func nearbyEventCard(_ card: NearbyEventCard, selected: Bool) -> some View {
    Button {
      guard let eventCodeHashHex = card.joinActionEventCodeHashHex else { return }
      // Re-read the clock preflight at the moment of joining, as Android does:
      // shared re-measures an expired cache and catches a clock changed since
      // the scan opened.
      if let clockPreflight {
        Task { await clockPreflight.check() }
      }
      sensing.joinNearbyEvent(eventCodeHashHex: eventCodeHashHex)
    } label: {
      BeidPanel {
        VStack(alignment: .leading, spacing: DS.Space.s) {
          Text(beaconNameLabel)
            .font(DS.Font.meta)
            .foregroundStyle(DS.Color.textSecondary)

          Text(verbatim: displayName(for: card))
            .font(DS.Font.cardTitle)
            .foregroundStyle(DS.Color.textPrimary)

          if card.eventIdHex != nil {
            Label(verifiedLabel, systemImage: "checkmark.shield.fill")
              .font(DS.Font.meta)
              .foregroundStyle(DS.Color.textSecondary)
          } else {
            Label(waitingForVerificationLabel, systemImage: "clock")
              .font(DS.Font.meta)
              .foregroundStyle(DS.Color.textSecondary)
          }

          if let validityPeriod = validityPeriod(for: card) {
            Text(validityPeriod)
              .font(DS.Font.meta)
              .foregroundStyle(DS.Color.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }

          if selected {
            Label(selectedLabel, systemImage: "checkmark.circle.fill")
              .font(DS.Font.meta)
              .foregroundStyle(DS.Color.textSecondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .buttonStyle(.plain)
    .disabled(card.joinActionEventCodeHashHex == nil || !isPreJoin)
    .accessibilityIdentifier("scan.nearby-event.\(card.eventCodeHashHex)")
  }

  private func displayName(for card: NearbyEventCard) -> String {
    if card.hasDisplayNameConflict {
      return conflictingNamesLabel
    }
    return card.beaconDisplayName ?? missingBeaconNameLabel
  }

  private var manualEntryTitle: String {
    String(
      localized: "nearbyEvent.manualEntry.button",
      defaultValue: "Enter event code",
      comment: "Secondary action on the nearby-event scan screen that opens manual event-code entry when discovery does not find the user's event."
    )
  }

  private var searchingTitle: String {
    String(
      localized: "nearbyEvent.searching.title",
      defaultValue: "Searching for nearby events…",
      comment: "Status shown while the pre-join Bluetooth scan has not found any nearby event candidates."
    )
  }

  private var rescueGuidance: String {
    String(
      localized: "nearbyEvent.searching.rescue",
      defaultValue: "If no event appears, enter the event code instead.",
      comment: "Guidance below the empty nearby-event list; the manual code-entry button is directly below this content."
    )
  }

  private var beaconNameLabel: String {
    String(
      localized: "nearbyEvent.beaconName.label",
      defaultValue: "Name announced by nearby beacon",
      comment: "Label above an event name received from a nearby Bluetooth beacon. The name is an untrusted announcement, not a verified event identity."
    )
  }

  private var missingBeaconNameLabel: String {
    String(
      localized: "nearbyEvent.beaconName.missing",
      defaultValue: "No name announced by nearby beacon",
      comment: "Fallback shown when a nearby Bluetooth candidate has no display name. The candidate remains visible."
    )
  }

  private var conflictingNamesLabel: String {
    String(
      localized: "nearbyEvent.beaconName.conflict",
      defaultValue: "Multiple names reported nearby",
      comment: "Warning shown when nearby beacons announce different names for the same event-code hash. Do not choose one of the names as authoritative."
    )
  }

  private var waitingForVerificationLabel: String {
    String(
      localized: "nearbyEvent.verification.waiting",
      defaultValue: "Waiting for event verification",
      comment: "Non-interactive nearby-event card status: registry evidence is not currently sufficient to join this candidate."
    )
  }

  private var verifiedLabel: String {
    String(
      localized: "nearbyEvent.verification.verified",
      defaultValue: "Verified",
      comment: "Status on an interactive nearby-event card whose registry evidence currently permits a join. This is separate from the display-only Selected state."
    )
  }

  private func validityPeriod(for card: NearbyEventCard) -> String? {
    guard
      let validFromEpochSeconds = card.displayValidFromEpochSeconds,
      let validUntilEpochSeconds = card.displayValidUntilEpochSeconds
    else { return nil }
    let start = Date(timeIntervalSince1970: TimeInterval(validFromEpochSeconds))
      .formatted(date: .abbreviated, time: .shortened)
    let end = Date(timeIntervalSince1970: TimeInterval(validUntilEpochSeconds))
      .formatted(date: .abbreviated, time: .shortened)
    let format = String(
      localized: "nearbyEvent.validityPeriod",
      defaultValue: "Valid %1$@ – %2$@",
      comment: "Display-only validity period on a verified nearby-event card. The first value is the start date and time; the second is the end date and time. It never authorizes a join."
    )
    return String(format: format, locale: Locale.current, arguments: [start, end])
  }

  private var selectedLabel: String {
    String(
      localized: "nearbyEvent.selected",
      defaultValue: "Selected",
      comment: "Display-only status on the sole currently joinable nearby-event card. The user must still tap the card to join."
    )
  }

  private var radar: some View {
    ZStack {
      ForEach(0..<3, id: \.self) { index in
        Circle()
          .stroke(.tint.opacity(0.34), lineWidth: 2)
          .scaleEffect(pulse ? 1.6 : 0.48)
          .opacity(pulse ? 0 : 0.75)
          .animation(reduceMotion ? nil : pulseAnimation(delay: Double(index) * 0.5), value: pulse)
      }

      BeidGlyph(
        systemImage: "dot.radiowaves.left.and.right",
        assetImage: "encounter-field-pulse",
        tint: .accentColor,
        size: DS.Size.radarCore
      )
    }
    .frame(width: DS.Size.radarField, height: DS.Size.radarField)
  }

  private func pulseAnimation(delay: Double) -> Animation {
    .easeOut(duration: 1.8)
      .repeatForever(autoreverses: false)
      .delay(delay)
  }
}

#Preview {
  let coordinator = AppCoordinator()
  return SensingView(sensing: coordinator.sensingCoordinator)
    .environmentObject(coordinator)
}

#Preview("Dark") {
  let coordinator = AppCoordinator()
  return SensingView(sensing: coordinator.sensingCoordinator)
    .environmentObject(coordinator)
    .preferredColorScheme(.dark)
}
