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
        .fill(DS.Color.surfaceRaised)
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
