// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

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
          VStack(spacing: DS.Space.l) {
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
          .padding(.horizontal, DS.Space.pageMargin)
          .padding(.vertical, DS.Space.l)
        }
      }
    }
    // Sensing screen: actionPrimary tint — Flat 2b has one ink and no
    // per-screen motif accents (DESIGN.md §5). The radar rings use this
    // tint through `.tint.opacity(...)`.
    .tint(DS.Color.actionPrimary)
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
        .beidBottomBar()
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
  /// in `textPrimary`: Flat 2b has no error color, and the words carry the
  /// meaning (DESIGN.md §5).
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
      Text(message)
        .font(DS.Font.supporting)
        .foregroundStyle(DS.Color.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
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

  /// What a nearby card's tap does, as a named method rather than a closure
  /// buried in the `Button` below, so `BeidTests` can run it (beid#464).
  ///
  /// Not `private`, and the same seam shape
  /// `SensingCoordinator.handleEventInfoHint` already uses: a closure inside
  /// a SwiftUI `Button` is unreachable from a test without a view-inspection
  /// dependency this repository does not have, which left the join-time clock
  /// check below asserted by nothing. Order is load-bearing and matches
  /// Android's `EventJoinViewModel.joinNearbyEvent`: refuse a card shared did
  /// not make joinable, then re-read the clock, then join.
  func joinNearbyEventTapped(_ card: NearbyEventCard) {
    guard let eventCodeHashHex = card.joinActionEventCodeHashHex else { return }
    // Re-read the clock preflight at the moment of joining, as Android does:
    // shared re-measures an expired cache and catches a clock changed since
    // the scan opened.
    if let clockPreflight {
      Task { await clockPreflight.check() }
    }
    sensing.joinNearbyEvent(eventCodeHashHex: eventCodeHashHex)
  }

  private func nearbyEventCard(_ card: NearbyEventCard, selected: Bool) -> some View {
    Button {
      joinNearbyEventTapped(card)
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
            Text(verbatim: verifiedLabel)
              .font(DS.Font.meta)
              .foregroundStyle(DS.Color.textSecondary)
          } else {
            Text(verbatim: waitingForVerificationLabel)
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
            Text(verbatim: selectedLabel)
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

      // Interim bordered roundel; #634 owns the final radar center.
      Circle()
        .fill(DS.Color.surfaceCanvas)
        .overlay {
          Circle().strokeBorder(DS.Color.strokeHairline, lineWidth: 1)
        }
        .frame(width: DS.Size.radarCore, height: DS.Size.radarCore)
        .accessibilityHidden(true)
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

/// The live, joined-event portion of Flat 2b's 05 family. Values are read
/// from the same coordinator that records the session. Figma's counts and
/// event details are examples, never defaults for a production session.
struct SensingSessionSurface: View {
  enum Presentation: Equatable {
    case detecting
    case detectingLong
    case detectingFirstTime
    case steady

    var showsEdges: Bool {
      switch self {
      case .detecting, .detectingLong, .detectingFirstTime: false
      case .steady: true
      }
    }
  }

  @ObservedObject var sensing: SensingCoordinator
  let event: EventSession
  let presentation: Presentation
  var diagnosticCaption: String? = nil
  var onRetryVerification: () -> Void = {}

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { timeline in
      let now = sensing.sensingPresentationNow(timeline.date)
      GeometryReader { geometry in
        let contentWidth = max(0, geometry.size.width - 2 * DS.Space.pageMargin)
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            if presentation == .steady {
              eventHeading
            } else {
              eventHeading.accessibilityIdentifier("scan.event-found")
            }

            if let eventSubtitle = eventSubtitle {
              Text(verbatim: eventSubtitle)
                .beidTextStyle(DS.Font.Library.body15)
                .foregroundStyle(DS.Color.textSecondaryOnInk)
                .padding(.top, DS.Space.s)
            }

            SensingRadarView(
              peers: radarPeers,
              mutualDeviceCount: Int(sensing.sessionAggregate?.mutualDeviceCount ?? 0),
              observedWindowCount: observedWindowCount ?? 0,
              showsEdges: presentation.showsEdges,
              size: max(0, min(DS.Size.radarField, geometry.size.width - DS.Space.pageMargin))
            )
            // Keep the measured radar centered without widening the inset content.
            .frame(width: contentWidth)
            .padding(.top, DS.Space.m)

            SensingWindowBars(aggregate: sensing.sessionAggregate, firstSightingAt: sensing.firstSightingAt)
              .frame(width: contentWidth)
              .padding(.top, DS.Space.l)

            Rectangle()
              .fill(DS.Color.strokeHairlineOnInk)
              .frame(width: contentWidth, height: DS.Size.hairline)
              .padding(.top, DS.Space.l)

            metrics(at: now)
              .padding(.top, DS.Space.m)

            if EventIdentityVerificationPresentation.forStatus(event.identityVerification) != nil {
              BeidPanel {
                EventIdentityVerificationRow(
                  status: event.identityVerification,
                  onRetry: onRetryVerification
                )
              }
              .padding(.top, DS.Space.m)
            }

            if let diagnosticCaption {
              Text(verbatim: diagnosticCaption)
                .beidTextStyle(DS.Font.Library.body13)
                .foregroundStyle(DS.Color.textSecondaryOnInk)
                .padding(.top, DS.Space.s)
            }

            Spacer(minLength: DS.Space.m)
            footer(at: now)
              .frame(maxWidth: .infinity)
          }
          .frame(minHeight: geometry.size.height, alignment: .top)
          .padding(.horizontal, DS.Space.pageMargin)
        }
      }
    }
    .background(DS.Color.textPrimary.ignoresSafeArea())
    .accessibilityIdentifier("scan.sensing-session")
  }

  private var eventHeading: some View {
    Text(verbatim: event.name)
      .beidTextStyle(DS.Font.Library.display46)
      .foregroundStyle(DS.Color.labelOnActionPrimary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: 220, alignment: .leading)
      .accessibilityAddTraits(.isHeader)
  }

  private var observedWindowCount: Int? {
    guard let aggregate = sensing.sessionAggregate else { return nil }
    // This is a sparse count of windows with an observation, including the
    // currently open first window; it is not elapsed ENIN positions.
    return Int(aggregate.windowCount)
  }

  private var eventSubtitle: String? {
    let since = sensing.firstSightingAt?.formatted(date: .omitted, time: .shortened)
    switch (event.venue, since) {
    case (let venue?, let time?): return "\(venue) · since \(time)"
    case (let venue?, nil): return venue
    case (nil, let time?): return "Since \(time)"
    case (nil, nil): return nil
    }
  }

  private var radarPeers: [SensingRadarPeer] {
    sensing.detectedDisplayIDs.sorted().map { id in
      SensingRadarPeer(id: id, signalStrength: sensing.signalStrength(forNodeId: id))
    }
  }

  private func metrics(at now: Date) -> some View {
    let elapsed = sensing.firstSightingAt.map { max(0, Int(now.timeIntervalSince($0))) }
    // The mutual count is shared's actual mutual scope. It is zero today
    // because no production observation carries reciprocal evidence; it is
    // never inferred from signal strength or the all-observation count.
    var items = [
      SensingMetric(value: String(sensing.sessionAggregate?.mutualDeviceCount ?? 0), label: "MUTUAL"),
      SensingMetric(value: String(sensing.devicesVerified), label: "DETECTED")
    ]
    if let elapsed {
      let isSearching = effectivePresentation(at: now) == .detectingLong
      items.append(SensingMetric(
        value: isSearching && elapsed < 60
          ? String(format: "0:%02d", elapsed)
          : "\(elapsed / 60)′",
        label: isSearching ? "SEARCHING" : "ELAPSED"
      ))
    }
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
        + "window \(observedWindowCount ?? 0)"
    )
  }

  private func effectivePresentation(at now: Date) -> Presentation {
    guard presentation == .detecting,
      let firstSightingAt = sensing.firstSightingAt,
      now.timeIntervalSince(firstSightingAt) >= 20
    else { return presentation }
    return .detectingLong
  }

  @ViewBuilder
  private func footer(at now: Date) -> some View {
    switch effectivePresentation(at: now) {
    case .detecting:
      Text("Looking for peers · stay nearby")
        .beidTextStyle(DS.Font.Library.labelMono9)
        .foregroundStyle(DS.Color.textSecondaryOnInk)
    case .detectingLong:
      NavigationLink {
        EventCodeEntryView(mode: .scanFlow)
      } label: {
        BeidTextControlLabel(
          "Not finding it? Enter event code",
          glyph: .trailing("→", announcing: "Enter event code"),
          labelColor: DS.Color.labelOnActionPrimary
        )
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("scan.manual-entry")
    case .detectingFirstTime:
      // 15 About sensing is owned by Stream A and does not exist yet. The
      // first-time Figma footer is omitted until its destination is real.
      EmptyView()
    case .steady:
      EmptyView()
    }
  }
}

struct SensingMetric: Identifiable {
  let value: String
  let label: String
  var id: String { label }
}

/// Six most recently observed windows. Each column represents one actual
/// shared aggregate row; missing future slots stay a low neutral line.
/// Gaps in ENIN indices are not filled as if observations happened there.
struct SensingWindowBars: View {
  let aggregate: BeidSharedKit.aggregation.SessionAggregate?
  let firstSightingAt: Date?
  var endsSession = false

  private var peerCounts: [Int] {
    guard let aggregate else { return [] }
    return Array((0..<Int(aggregate.windowCount))
      .compactMap { aggregate.windowAt(index: Int32($0)).map { Int($0.peerCount) } }
      .suffix(6))
  }

  var body: some View {
    VStack(spacing: DS.Space.s) {
      GeometryReader { geometry in
        let barGap: CGFloat = 6
        HStack(alignment: .bottom, spacing: barGap) {
          ForEach(0..<6, id: \.self) { index in
            Rectangle()
              .fill(color(at: index))
              .frame(
                width: max(0, (geometry.size.width - barGap * 5) / 6),
                height: height(at: index)
              )
          }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
      }
      .frame(height: 40)

      HStack {
        if let firstSightingAt {
          Text(firstSightingAt.formatted(date: .omitted, time: .shortened))
            .foregroundStyle(DS.Color.textSecondaryOnInk)
        }
        Spacer()
        Text(endsSession ? "END" : "NOW")
          .foregroundStyle(DS.Color.labelOnActionPrimary)
      }
      .beidTextStyle(DS.Font.Library.labelMono10Tight)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("window \(Int(aggregate?.windowCount ?? 0))")
  }

  private func color(at index: Int) -> Color {
    guard index < peerCounts.count else { return DS.Color.strokeHairlineOnInk }
    return index == peerCounts.count - 1
      ? DS.Color.labelOnActionPrimary
      : DS.Color.strokeHairlineOnInk
  }

  private func height(at index: Int) -> CGFloat {
    guard index < peerCounts.count else { return DS.Space.xs }
    return min(40, DS.Space.xs + CGFloat(peerCounts[index]) * 2)
  }
}

/// Keeps the existing B005 discovery list available before an event is
/// joined, and promotes an actual join refusal to frame 05d's layout.
/// A clock that is off or could not be checked is not a refusal: it stays on
/// this screen as `ClockPreflightNoticeView` above an enabled nearby list, as
/// it did before the Flat 2b redesign and as it does on Android.
struct SensingPrejoinRouter: View {
  @ObservedObject var sensing: SensingCoordinator
  let clockPreflight: ClockPreflightController

  var body: some View {
    if let reason = SensingCantJoinReason(joinRefusalKey: sensing.joinRefusalReasonKey) {
      SensingCantJoinView(
        reason: reason,
        code: sensing.joinedEventCode,
        event: nil,
        candidate: nil
      )
    } else {
      SensingView(sensing: sensing, clockPreflight: clockPreflight)
    }
  }
}

enum SensingCantJoinReason {
  case refused(String)

  init?(joinRefusalKey: String?) {
    guard let joinRefusalKey else { return nil }
    self = .refused(joinRefusalKey)
  }

  var status: String {
    switch self {
    case .refused: "Can't join"
    }
  }

  var title: LocalizedStringKey {
    switch self {
    case .refused(let key):
      switch key {
      case "network_required": "No network connection"
      case "event_not_found": "Code not registered"
      case "code_mismatch": "Code mismatch"
      case "event_not_active": "Event not open"
      default: "Couldn't verify this event"
      }
    }
  }

  var message: LocalizedStringKey {
    switch self {
    case .refused(let key):
      switch key {
      case "network_required":
        "beid needs a connection to verify this event, and couldn't reach the network. Check your connection and try again."
      case "event_not_found":
        "No event is registered for that code. Check it with the event organizer."
      case "code_mismatch":
        "That code didn't match the event beid found. Check that you have the whole code."
      case "event_not_active":
        "That event isn't open to join right now."
      case "verification_failed":
        "beid couldn't verify that event. Check the code with the event organizer."
      default:
        "beid couldn't join that event. Check the code and try again."
      }
    }
  }
}

/// Frame 05d. The illustrated registry rows are shown only when a caller
/// supplies correlated event/candidate evidence; a real prejoin clock or
/// refusal path commonly has neither, so it never claims sample values.
struct SensingCantJoinView: View {
  let reason: SensingCantJoinReason
  let code: String?
  let event: EventSession?
  let candidate: NearbyEventCard?

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          Text(verbatim: event?.name ?? code ?? "Can't join")
            .beidTextStyle(DS.Font.Library.display46)
            .foregroundStyle(DS.Color.labelOnActionPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 220, alignment: .leading)
            .accessibilityAddTraits(.isHeader)

          if let venue = event?.venue {
            Text(verbatim: "\(venue) · found nearby")
              .beidTextStyle(DS.Font.Library.body15)
              .foregroundStyle(DS.Color.textSecondaryOnInk)
              .padding(.top, DS.Space.s)
          }

          Text("Why")
            .beidTextStyle(DS.Font.Library.labelMono10)
            .foregroundStyle(DS.Color.textSecondaryOnInk)
            .padding(.top, DS.Space.l)

          Text(reason.title)
            .beidTextStyle(DS.Font.Library.title19)
            .foregroundStyle(DS.Color.labelOnActionPrimary)
            .padding(.top, DS.Space.s)
            .accessibilityIdentifier("scan.join-refusal")

          Text(reason.message)
            .beidTextStyle(DS.Font.Library.body15)
            .foregroundStyle(DS.Color.textSecondaryOnInk)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, DS.Space.s)

          if event != nil || candidate != nil {
            eventIdentity
              .padding(.top, DS.Space.xl)
          }

          Spacer(minLength: DS.Space.xl)
          NavigationLink {
            EventCodeEntryView(mode: .scanFlow)
          } label: {
            BeidTextControlLabel("Enter event code instead", labelColor: DS.Color.labelOnActionPrimary)
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("scan.manual-entry")
        }
        .frame(minHeight: geometry.size.height, alignment: .top)
        .padding(.horizontal, DS.Space.pageMargin)
      }
    }
    .background(DS.Color.textPrimary.ignoresSafeArea())
    .accessibilityIdentifier("scan.cant-join")
  }

  private var eventIdentity: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Event identity")
        .beidTextStyle(DS.Font.Library.labelMono10)
        .foregroundStyle(DS.Color.textSecondaryOnInk)
        .padding(.bottom, DS.Space.s)

      if let event {
        if event.identityVerification == .verified {
          identityRow("Registry", value: "Verified")
        }
        identityRow("Code", value: event.id)
      }
      if let candidate, candidate.joinActionEventCodeHashHex != nil {
        identityRow("Open to join", value: "Yes")
      }
    }
  }

  private func identityRow(_ title: String, value: String) -> some View {
    VStack(spacing: 0) {
      Rectangle()
        .fill(DS.Color.strokeHairlineOnInk)
        .frame(height: DS.Size.hairline)
      HStack {
        Text(verbatim: title)
          .foregroundStyle(DS.Color.textSecondaryOnInk)
        Spacer()
        Text(verbatim: value)
          .foregroundStyle(DS.Color.labelOnActionPrimary)
      }
      .beidTextStyle(DS.Font.Library.labelMono10)
      .frame(minHeight: DS.Size.minHitTarget)
    }
  }
}
