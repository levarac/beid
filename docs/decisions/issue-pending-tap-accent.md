# What can be tapped: one interaction accent, three button tiers, and the Flat 2b rules they change

**Status:** proposed 2026-11-18. The accent values were chosen by the maintainer on 2026-11-19 from side-by-side screenshots of three candidates (blue, teal, violet): teal. The structural rules take effect for iOS when the maintainer accepts this record and the implementing PRs merge; Android follows later (see "Platform scope"). Every "Superseded 2026-11-18" block and every 2026-11-18 annotation in `DESIGN.md` points here (below: "D-tap-accent"). The tracking issue for this change is still to be filed; this file is named `issue-pending-tap-accent.md` until it is, and is renamed to carry the issue number then. The two accent value pairs are ratified (maintainer decision 2026-11-19) and carry no tag; the structural rules carry no tag but are part of what is proposed.

**Authority.** The maintainer, after using the iOS 1.1.1 build in the simulator on 2026-11-18:

> Across the app the button treatment is weak: it is not intuitive what can be tapped and what cannot. The monotone color may be part of the problem. Keep the tone and manner, and improve the UI from this angle.
>
> The Figma design is not absolute; implementation surfaces adjustments.

(Both statements were made in Japanese; this is a translation.) This record rests on those statements. It does not restate who decided Flat 2b; D-627 records that differently. Copy is out of scope: no string is added or changed.

## The problem, measured at 3285056e

- In-content controls are bare DM Mono 11 uppercase text, in the same face and case as the labels around them, and often the same color. There are 19 `BeidTextControl` and 11 `BeidTextControlLabel` call sites.
- The app tint `actionPrimary` is the same ink as body text (`Tokens.swift:50-52`, `RootView.swift:35`), so even system-tinted controls read as text.
- No control draws a pressed or disabled state. There is no `ButtonStyle` conformance, there are 32 `.buttonStyle(.plain)` uses, and disabled controls keep explicit label colors.
- Static things carry the button shapes: capsule chips (`BeidStatusPill`, the `EventCardView` badge), gray tiles, a filled DONE box in the button slot (`RecordingView.swift:124-136`) and a white panel on black (`SensingView.swift:609-617`). The tappable nearby-event card is drawn like the static panels next to it.
- Some controls are ink on ink: FIX → on the ink Now page (`CollectionHomeView.swift:257`), and VIEW RECORD → and WHAT WAS SENT → when the saved summary renders on ink.
- No existing gray can mark a control's boundary: `line` on `bg` is 1.18:1 and `tile` on `bg` is 1.12:1.

## What is adopted

1. **One interaction accent, one meaning: "you can tap this, now."** It is the hue of the teal ratified on 2026-07-10 (`#18C7A7`), darkened until it reaches 4.5:1 as text, with one value per ground:

   | Primitive (colorset) | Value | Increase Contrast | DS token | Ground |
   | --- | --- | --- | --- | --- |
   | `accent` | `#077763` | `#066352` | `actionAccent` | `bg`, `tile`, white panels and sheets, OS alerts |
   | `on-ink/accent` (`onInkAccent`) | `#059A80` | `#02A88C` | `actionAccentOnInk` | `ink` pages and cards, the Account sheet, ink bars |

   It colors:
   - text controls;
   - the trailing cue of tappable rows and cards;
   - secondary-capsule outlines and labels;
   - focus (the caret and the focused field's rule);
   - the selection mark of a tappable set (the selected tab, the chart selection rule);
   - the system tint: the root tint, ink-ground tints, the tab bar, alerts (always the canvas value, because alert surfaces are white), and the target's global accent color for alerts and the share sheet.

   Nothing that does not respond to a tap uses it.

2. **Ink keeps both Flat 2b jobs.** It is "what is happening now", and it is the one primary fill: an ink capsule on `bg` and a white (`actionInverse`) capsule on `ink`, at most one per screen. The tone is passed explicitly at each call site. Every ink surface fill (grounds, cards, bar backgrounds, sheet rows, the radar canvas) uses the `surfaceNow` role, not the text color.

3. **Three tiers in one capsule family, plus row cues.**
   - Primary: `BeidPrimaryButton`, a filled capsule in `DS.Font.cta`, at least 56 pt.
   - Secondary: `BeidSecondaryButton`, a transparent capsule with a 1 pt accent outline and an accent label. Large: full width, at least 56 pt. Regular: full width, at least 44 pt. Compact: hugs its label, at least 32 pt visible inside a hit region of at least 44×44 pt, in Label/Mono 11; its spoken label is the title as written.
   - Tertiary: `BeidTextControl`, accent DM Mono 11 uppercase with a typed glyph.
   - Rows and cards that act as one button carry a trailing accent cue: →, ↗, or the existing action word (JOIN, Rejoin).

   A screen's way forward is never tertiary text. A recovery screen's single way forward is primary.

4. **Typed glyphs, one meaning each.** → opens another screen in the app; ← returns to the parent; ↗ leaves the app; ↓ and ↑ expand and collapse a section in place. Actions that work in place carry no glyph.

5. **States.**
   - Pressed: filled capsules at 0.8 opacity, the Library's `Button/Primary` value, now implemented; everything else at 0.5. The change animates with `DS.Motion.fast`, and not at all under Reduce Motion.
   - Disabled: `.disabled()` is the only switch, and the accent leaves. Text, outlines and cues use `labelDisabled` (`#8E8E96`, lighter than the accent) or `labelDisabledOnInk` (`#5C5C66`, darker than the on-ink accent). Filled capsules drain to `actionDisabled` with `labelOnActionDisabled` (4.51:1), or `actionDisabledOnInk` with `labelOnActionDisabledOnInk` (4.38:1).
   - Busy: a primary that waits shows a small activity indicator inside the capsule.
   - Accessibility settings: enabled text controls, and the glyphless COPY, are underlined under Button Shapes, Differentiate Without Color or Increase Contrast.

6. **Look-alikes lose their button features.** Status chips and badges become a dot plus text. The filled DONE box on Record saved becomes a ruled block. The white status panel on the live sensing screen is removed. Gray tiles stay but never act. Static text in control-like positions (onboarding steps, the searching panel, RECORD ID / SEALED, Bluetooth ACTIVE, CLOCK OUT OF SYNC) keeps no accent, capsule or cue.

7. **The ground is declared, not remembered.** `BeidGround` (`.canvas` / `.ink`) is an environment value.
   - Screens paint their ground with `.beidScreenGround(_:)`.
   - Ink cards declare `.beidGround(.ink)`, and `BeidPanel` resets its content's ground to canvas. `BeidPanel` sets the environment value only and leaves the tint alone: the styles and text controls resolve their colors from the ground, while tint-driven content inside a panel (the `EventCardView` badge) keeps the tint of its screen. The panel's tint follows once that badge moves off `.tint`.
   - White destinations and sheets declare canvas where they are presented.
   - An OS alert attached inside an ink-capable subtree is followed by `.beidAlertTint()`.
   Components resolve their accent and disabled colors from the ground, so call sites no longer pass label colors.

8. **Figma is a reference, not an absolute authority.** Code may deviate when implementation finds a better value. Each deviation is recorded in `DESIGN.md` (a Superseded block or annotation, and a §C row) and in the PR's `DesignException:` line, and the Library is synced afterwards.

## Why this accent

- **Tone.** The hue appears only as thin marks: 11 pt mono text, 1 pt outlines, small cues, the caret, a 2 pt selection rule and the selected tab. There are no new fills, shadows, gradients, icons, grays or strings.
- **Hue.** It is the hue of the teal ratified on 2026-07-10 (`#18C7A7`), darkened until it reaches 4.5:1 as text; `#18C7A7` itself is 2.15:1 on white. It is named and explicit, never the implicit platform default.
- **Accepted consequences.** At these values the teal reads as a dark green, close to the semantic green used for "on" status (`semanticGreen` `#30D158`), so a stop action drawn in the accent (for example "Stop broadcasting") shows in a green-looking color. Under deuteranopia simulation the teal is ΔE00 6.5 from the gray secondary text (`sub`), against 21.2 for the blue candidate and 23.2 for the violet candidate. The maintainer accepted both on 2026-11-19; they are recorded as follow-ups (open item 1), not as reasons the choice is wrong.
- **Contrast windows.** No single value reaches 4.5:1 as text on both `bg` and `ink`, so there are two values. Each reaches AA on its own ground and stays at least 3:1 lighter or darker than the body text beside it. Under Increase Contrast the light value (`#066352`, 7.21:1 on `bg`) is only 2.73:1 against `ink` text, so the underline carries the separation there.
- **Considered and not taken.** The 2026-07-10 ratification rejected the Figma Minimal v4 blue (`#007AFF`). Alternatives prepared for the screenshot review: the brand-derived blue (`#3765C6` / `#5F87D7`, the Levarac brand hue at 60% of its chroma), a violet (`#7043F8` / `#8873FE`), the brand blue as is (`#014EFE` / `#4D86FF`), and a violet-blue on the hue cast the Flat 2b grays already share (`#7246FB` / `#8772FE`). Ink plus shapes alone would not answer "monotone may be the problem".

## Changed rules

Commits come from `git log -S` on `DESIGN.md`. Authors are omitted because this is a public repository.

| Old rule (verbatim) | Provenance | Replaced by |
| --- | --- | --- |
| §0: "MUST (steady state, confirmed 2026-09-22): The Flat 2b Library is the design authority for values. `Tokens.swift` is canonical for what ships and is the only place code reads values. A mismatch between the Library and `Tokens.swift` after the migration is a defect to file as an issue, not something resolved automatically in either direction." | `6b963317` (#627, 2026-09-22) | The Library is the reference design. Code may deviate; each deviation is recorded in `DESIGN.md` and the PR's `DesignException:` line, and syncing the Library is a follow-up rather than a defect. `Tokens.swift` stays the only place code reads values. |
| §5: "**Black, white and grays only**, plus **three semantic colors, each with one meaning**: red = destructive / off, amber = verifying / pending, green = active / on." | `6b963317` (#627) | Black, white and grays; three semantic colors with one meaning each; and one interaction accent meaning "you can tap this, now". |
| §5: "MUST: Only the Library colors above, through the `DS.Color.*` tokens named in the table. No per-event or per-proof hue." | `6b963317` (#627); token wording `978ca8f5` (#628, 2026-09-23) | Only the colors in §5's table — 13 Library variables plus 2 code-first accent variables — through the named tokens. No per-event or per-proof hue. |
| §5: "Flat 2b has no motif accents: there is one ink, and the three semantic colors each carry one meaning (above)." | `6b963317` (#627) | Still no motif or per-screen accents; the interaction accent means the same on every screen. |
| §5: "…every tintable control gets an explicit `DS.Color.*` tint, and the app-level accent is `actionPrimary`." | `79cd005` (2026-07-10); reworded `b65d5c9` (#153, 2026-08-08) | …and the app-level accent is `actionAccent` (`actionAccentOnInk` under an ink ground); the target's global accent color names `accent`; alerts presented from ink-capable subtrees take the canvas accent through `.beidAlertTint()`. The MUST NOT on implicit system blue stays. |
| §5 table: `sub` forbidden use "Primary CTAs" | `6b963317` (#627) | Also allowed as `labelOnActionDisabled`, the label of a disabled primary (4.51:1 on `actionDisabled`). |
| §5 table: `on-ink/sub` forbidden use "Text on `bg`"; `on-ink/idle` forbidden use "Text" | `6b963317` (#627) | Both are also allowed as disabled-control labels (3.25:1 on `bg`, 2.97:1 on `ink`); inactive components are exempt from AA (§13). |
| §8: "`BeidPrimaryButton` is `.borderedProminent` at `.controlSize(.large)` and `BeidSecondaryButton` `.bordered`, both a `DS.Radius.control` rounded rectangle; Home's icon Scan button is a `.borderedProminent` circle." … "Two gaps are left open deliberately: the primary button is not yet a pill (building `Button/Primary` is not assigned, §0), and `.bordered` is a system tint fill, not `bg` + `line`." | `9dcc560f` (#630, 2026-09-23) | Describes the code: a Capsule pill drawn by `BeidPrimaryButtonStyle`, and no Scan button. The secondary is a transparent capsule with a 1 pt `actionAccent` outline: the Library's `bg` + `line` intent, with a line that reaches 3:1 (`line` itself is 1.18:1). |
| §9: "SHOULD: Haptics only at meaningful commits: event found (light), proof sealed (success)." | §9 haptics SHOULD (`DESIGN.md:1466-1469`) | Unchanged as a rule; one commit is added to its list: copying the venue event ID gets a light haptic. No other haptic is added. |
| §12: "MUST: The app draws no icons in content. Controls inside a screen are monospaced uppercase text in DM Mono (§6): `COPY`, `PASTE`, `OPEN →`, `ENTER EVENT CODE →`." | `31550dc6` (#731, 2026-10-15) | No icons in content (kept). In-content controls use the three tiers; text controls stay DM Mono uppercase with typed glyphs of one meaning each; tappable rows carry a cue; in a native `List`, the OS disclosure indicator is the cue. |
| §13: "Open item 4 (D-627): non-text contrast under WCAG 1.4.11 is not covered by this section today, which covers text; recorded, no new rule." | `6b963317` (#627) | For controls: the identifying mark is at least 3:1; never color alone; accent text is at least 3:1 from adjacent body text in lightness or carries a non-color cue; disabled controls are exempt from AA but keep at least 2.5:1 and change in lightness; there is always a pressed state; text controls are underlined under Button Shapes, Differentiate Without Color or Increase Contrast. Charts stay open (#634, #640). |
| §16: "No icons: controls are monospaced text; the OS status bar is the only exception (§12)." | `6b963317` (#627) | No icons in content; in-content controls use the three tiers (§10); the OS status, navigation, toolbar and tab bars are the exceptions (§12). |

## Preserved rules

- §1's tone thesis and its "MUST NOT feel like" list. §3's four motifs, including the DON'T on a system blue accent (`DESIGN.md:470-474`, kept by the D-627 annotation at `:487-494`): this accent is named, explicit and in the ratified teal hue, never the implicit platform default, and §3 gets a 2026-11-18 annotation saying so.
- Black is "what is happening now". The primary CTA is an `ink` fill with a `bg` label (§5), one per screen, with Tone=Inverse on `ink`.
- Red, amber and green keep one meaning each, as indicators: dots on `bg`, text only on `ink`. Stop and "off" actions are not red.
- No per-event hue. Single appearance (§14). No glass, materials, blur, shadows or gradients on app-drawn surfaces. OS-standard bars, with no suppressed glass.
- Hit regions of at least 44×44 pt. Never color alone. Dynamic Type with minimum heights. §15 copy, with no string added or changed. Token names describe roles. `DESIGN.md` holds no values.

## Measured contrast (WCAG 2.x, sRGB, 2026-11-19)

| Pair | Ratio |
| --- | --- |
| `actionAccent` on `bg` / `tile` | 5.49 / 4.91 |
| `actionAccent` vs `ink` body text | 3.58 |
| `bg` glyph on an `actionAccent` fill | 5.49 |
| `actionAccentOnInk` on `ink` / on `on-ink/line` | 5.56 / 4.03 |
| `actionAccentOnInk` vs `bg` text; `bg` glyph on it | 3.54 / 3.54 |
| Increase Contrast `#066352` on `bg` / `tile`; vs `ink` text | 7.21 / 6.44; 2.73 |
| Increase Contrast `#02A88C` on `ink`; vs `bg` text and `bg` glyph on it | 6.53 / 3.01 |
| `labelDisabled` on `bg`; vs `actionAccent` (lightness) | 3.25 / 1.68 |
| `labelDisabledOnInk` on `ink`; vs `actionAccentOnInk` | 2.97 / 1.87 |
| `labelOnActionDisabled` on `actionDisabled` | 4.51 |
| `labelOnActionDisabledOnInk` on `actionDisabledOnInk` | 4.38 |
| Pressed ink capsule (`#3C3C3F`) with `bg` label, the control faded as one composited layer over `bg` | 10.99 |
| Pressed white capsule (`#CECECF`) with `ink` label, over `ink` | 12.49 |
| Selected chart bar (`ink`) vs unselected (`#92929A`); selection rule on `bg` | 6.36 / 5.49 |

## Open items

1. Follow-ups from the accepted consequences of the teal (see "Why this accent"; no new rule is added here): a stop action drawn in the accent reads as green, near `semanticGreen`; and under deuteranopia the accent is hard to tell from the gray secondary text (ΔE00 6.5). Check both on a device with the teal in place.
2. #24 (capitalization) stays open. Capsules show their strings as written. "I’ve turned it on", "Try again" and "Enter event code instead" appear in sentence case. "STOP SENSING", "KEEP SENSING", "OPEN DETAILS", "ENTER EVENT CODE" and "JOIN" appear in uppercase.
3. Existing strings in new places: "JOIN" as the cue on the Sensing nearby cards, and "Rejoin" as the cue on Past events rows.
4. Figma Library sync: add `accent`, `on-ink/accent`, `Button/Secondary` (outline, three sizes), the pressed, disabled and busy states, and the row cue.
5. DM Mono Medium has no arrow glyphs (U+2190–21FF), so → ← ↗ ↓ ↑ render from a fallback face, as → does today. DM Sans Bold has them; rendering arrows in it is a possible follow-up.
6. Not yet verified on a device:
   - how iOS 26 draws bar items, the selected tab on ink and the prominent confirm item under the new tint;
   - whether SwiftUI alerts follow the global accent and `.tint`, including the clock alert presented from the ink Now page;
   - whether `.textCase(.uppercase)` reaches the XCUITest label (the compact tier pins its label either way);
   - whether the By event `List` also draws the OS chevron.
7. Native-component work (#838, #839, session detail #811) adopts the ground contract: in native lists the OS disclosure indicator is the row cue, and Button rows take the ground tint.
8. Not changed here: `BeidPrimaryButton` fires a haptic on every tap (§9); `VenueLinkScannerView.swift:90` uses a non-continuous corner; `Divider()` and DS hairlines are mixed on Now; ALL RECORDS duplicates Back.
9. Android: no follow-up is scheduled (see "Platform scope").
10. Figma follows the code later (maintainer decision 2026-11-18: Figma is not absolute; adjust in code and record it here). The Library sync in item 4 is that follow-up.
11. The target-wide global accent color (`ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: accent` in `ios/project.yml`, Beid target only) is not set by the first implementing change, because it needs the project to be regenerated with the pinned XcodeGen. Do it with the next regeneration. Until then, UIKit-drawn alerts and the share sheet can still show the implicit system blue.
12. `BeidSecondaryButton` keeps its soft haptic by default (`haptic: .soft`) so its two existing call sites stay unchanged, even though §9 prefers haptics only at meaningful commits. Flip the default to none once those call sites pass `.soft` explicitly.
13. Add this assertion to `ClockPreflightUITests.swift` when that file can change: `XCTAssertEqual(app.buttons["scan.clock-preflight.retry"].label, "Check again")`. The button is reachable in the UI fixtures and goes through the same `.accessibilityLabel(Text(accessibilityLabel ?? title))` path as the registry retry, so it pins the spoken label as written and answers whether the uppercase rendering leaks into the XCUITest label (open item 6).
14. BeidLab is built with the change that sets the global accent in `ios/project.yml` (open item 11); its sources include all of `ios/Beid`, including the colorsets, and it must still build.
15. The tracking issue is to be filed (English, levarac/beid, milestone "v1.1 画面を整えて一般イベントを開ける"); then rename this file and replace "pending" in the `DESIGN.md` links.

## Risks and temporary states

The styles and shared controls land before the screens that use them. Until those screens migrate, these states are visible. This package does not ship ahead of the screen packages that migrate the Now page (package 1), the pre-join inset (package 2) and the event card badge (the screen change that replaces it).

- On the ink Now page, default-colored text controls draw the canvas accent `#077763` on ink at 3.58:1, below 4.5:1 for 11 pt text; before, they were ink on ink. This covers FIX → and VIEW RECORD → / WHAT WAS SENT → (`CollectionHomeView.swift`). Package 1 declares the ink ground there.
- The pre-join "Enter event code" `.bordered` inset (`SensingView.swift`) sits outside the screen's own tint and picks up the root accent. Package 2 replaces it.
- The `EventCardView` badge keeps `.foregroundStyle(.tint)` and `.tint.opacity`. Because `BeidPanel` leaves the tint alone, it keeps the tint of its screen (the ink-colored `actionPrimary` on Signal lost). It becomes dot plus text with the screen change that replaces it.
- The Account toolbar item and the selected tab on the ink Now bar are drawn in the canvas accent (`#077763`) on ink until package 1 declares the ink ground there.
- Until the global accent in `ios/project.yml` is set (open item 11), UIKit-drawn alerts, the share sheet and any sheet the tint does not reach stay system blue.

## Implementing work

| Package | Files | Scope |
| --- | --- | --- |
| 0 | `Tokens.swift`; `Colors.xcassets` (`accent`, `onInkAccent`); `DesignSystem.swift` (grounds, control palette, the four button styles, row cue; `BeidPrimaryButton`, `BeidSecondaryButton`, `BeidStatusPill`, `BeidPanel`); `BeidTextControl.swift`; `EventIdentityVerificationRow.swift`; `ClockPreflightNoticeView.swift`; `RootView.swift`; `DesignTokensTests.swift`; `BeidTextControlTests.swift`; `DESIGN.md`; this record | Tokens, styles, ground, shared components, tint. Not in this package: the `EventCardView` badge (moves with the screen packages, see "Risks and temporary states"), the global accent in `project.yml` (open item 11), a separate styles source file and test file (the Xcode project lists files explicitly and is regenerated separately), and a UI assertion for the retry label (open item 13) |
| 1 | `CollectionHomeView.swift` | Now and Records |
| 2 | `SensingView.swift`, `SensingRadarView.swift`, `EventFoundView.swift`, `RecordingView.swift`, `SignalLostView.swift` | Sensing surfaces |
| 3 | `ScanFlowView.swift`, `SensingStopConfirmView.swift`, `ProofCollectedView.swift` | Scan-flow chrome, stop confirmation, Record collected |
| 4 | `EventCodeEntryView.swift`, `BluetoothOffView.swift`, `WelcomeView.swift` | Event code and onboarding |
| 5 | `AccountSheetView.swift`, `AboutSensingView.swift`, `PastEventsView.swift` | Account sheet, About, Past events |
| 6 | `OrganizerToolsView.swift`, `VenueSignedServingView.swift`, `VenueLinkScannerView.swift` | Organizer and venue |
| 7 | `EventDetailView.swift`, `EventReportRow.swift`, `ItemDetailView.swift`, `ObservationDetailView.swift`, `ReportDetailView.swift` | Record, event, session and report detail |

## Platform scope

**iOS-specific mechanism, with the Android counterpart named.** The principles are platform-neutral:
- one interaction accent with one meaning;
- three tiers plus row cues;
- one meaning per typed glyph;
- disabled controls without the accent.

The mechanism is iOS's: colorsets, `ButtonStyle`, the environment and tint. On Android:
- the tiers map to Material 3 `Button` (filled, primary), `OutlinedButton` (secondary) and `TextButton` (tertiary);
- the row cue maps to `ListItem` trailing content;
- the two accent values belong in `BeidPalette` / `BeidColorScheme`.

Android still ships the superseded palette and its own `BeidPrimaryButton` / `BeidSecondaryButton`. As with D-627, it is not in violation until a follow-up is scheduled, and none is.

BeidLab (the device-harness app target) compiles the Beid sources but shows only its own harness screen, so it carries no global accent setting; it must still build.