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
