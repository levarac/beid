# Android v1 UI polish design

## Goal

Make the existing Android participation and record surfaces feel intentional
and understandable while preserving the current state machine, navigation, and
truthful status vocabulary. This is a presentation-only slice for the current
candidate. It does not add screens, domain state, animations, adaptive
navigation, or new acceptance conditions.

## Surface decisions

`EventJoinContent` keeps its existing nearby discovery and rescue behavior, but
uses a small Material 3 top app bar with the account action. The body starts
with a short explanation of automatic discovery, then presents each nearby
candidate as a selectable panel. Joinable and unverified candidates remain
visibly distinct and only a verified candidate receives the join affordance.
The manual code route remains secondary and gets helper copy and a labelled
field. The UI never calls a candidate verified unless the existing model says
it is joinable.

`ScanFlowScreens` makes each phase a compact state panel: a status pill, a
phase heading, supporting explanation, and only the controls valid for that
phase. An indeterminate progress indicator is used only while discovery or
verification is unknown. Recording keeps the peer count prominent; signal loss
uses paused/resume language and preserves the count. Existing debug-only
signal-loss and wallet-binding controls remain available and visibly separate.

`RecordsScreen` and `TodaySummaryScreen` use clear empty states and compact
status rows. Submission labels remain queued, sending, retrying, stopped, and
accepted; accepted is never renamed to verified or anchored.

## Accessibility and verification

Important discrete state containers expose `stateDescription`; discovery and
submission changes use polite live-region semantics sparingly. Icons that carry
meaning receive descriptions, decorative glyphs remain unlabeled, and all
interactive controls retain the existing minimum touch sizes. Layout remains
scrollable so large font scales can reflow. Existing test tags and callbacks
are preserved. Meaningful Compose tests cover the hierarchy and key semantic
state; the configured debug APK is assembled after the focused test suite.

The design follows the official Material 3 Compose guidance for app bars and
the `Scaffold` structure, progress indicators, and Compose semantics:

- https://developer.android.com/develop/ui/compose/designsystems/material3
- https://developer.android.com/develop/ui/compose/components/app-bars
- https://developer.android.com/develop/ui/compose/components/progress
- https://developer.android.com/develop/ui/compose/accessibility/semantics

## Device review follow-up

The first device pass exposed three presentation problems in the actual Pixel
screens (`evidence/beid-pixel-46111JEKB11173/20260915-041-discovery.png`,
`20260915-041-event-code.png`, and `20260915-041-records.png`). The discovery
and code bodies were vertically centered below their app bars, leaving a large
empty gap before the primary content. Both now use local top-aligned scroll
layouts with roughly one spacing token of top padding; the shared `BeidScreen`
contract is unchanged. The discovery empty state is one panel containing the
current search/empty explanation and the manual rescue action, so the same
problem is not described twice. The code route has a back app-bar action,
shorter helper copy, and ASCII/no-autocorrect input hints while paste remains
the normal path for the long code.

The Records screenshot showed a 64-character raw event identifier dominating
each card. Since the Android record model has no event display name, list rows
now show `Event` plus a middle-ellipsized identifier and retain the full value
in accessibility semantics and the detail navigation payload. No record or
submission status fact changed.
