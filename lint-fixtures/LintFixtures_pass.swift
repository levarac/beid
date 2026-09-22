// Lint fixture — MUST produce ZERO violations (DESIGN.md §16).
// Not part of any compile target; linted only via the proof run in
// lint-fixtures/README.md. Exercises the sanctioned DS.* forms plus the
// known false-positive near-misses that the rules must NOT flag.

import SwiftUI

struct LintFixturesPass: View {
  var body: some View {
    VStack(spacing: DS.Space.m) {
      Text("Sensing")
        .font(DS.Font.sectionTitle)
        .foregroundStyle(DS.Color.textPrimary)
        .padding(DS.Space.l)
        .padding(.horizontal, DS.Space.m)
      // Allowed literals: 0 and 1 (hairlines / no-spacing).
      Divider()
        .padding(0)
        .padding(.top, 1)
      Spacer(minLength: 0)
      RoundedRectangle(cornerRadius: DS.Radius.card)
        .fill(DS.Color.surfaceTile)
        // shadow with a token color and a blur radius — blur radius is not
        // a corner radius and must not trip no_hardcoded_radius.
        .shadow(color: DS.Color.strokeHairline, radius: 2)
      // minLength on a non-Spacer API must not trip no_hardcoded_spacing.
      ScrollView { EmptyView() }
        .frame(minWidth: 44)
    }
    .animation(DS.Motion.proofResolve, value: UUID())
    .background(DS.Color.surfaceCanvas)
    .tint(DS.Color.actionPrimary)
  }
}

// no_glass_or_material near-misses taken from ios/Beid: an argument label
// ending in "Material" (ParticipantRelayVerifier), identifiers starting with
// "bar" (SensingCoordinator, VenueBundleVerification) and `.barcode`
// (VenueLinkScannerView).
struct LintFixturesPassGlassNearMisses: View {
  var body: some View {
    Text("Flat")
      .beidSurface(cornerRadius: DS.Radius.card)
      .onAppear {
        _ = Verifier.verify(randomnessSeedMaterial: nil)
        _ = Self.barnardDefinition(from: nil)
        _ = Self.barnardJoinMode(from: nil)
        _ = Scanner(recognizedDataTypes: [.barcode(symbologies: [.qr])])
      }
  }

  static func barnardDefinition(from context: String?) -> String? { context }

  static func barnardJoinMode(from mode: String?) -> String? { mode }

  func handle(_ item: RecognizedItem) {
    guard case .barcode(let barcode) = item else { return }
    _ = barcode
  }
}
