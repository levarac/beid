# Spec — Scan flow redesign, Slice 1: Sensing (Beid iOS)

Status: APPROVED 2026-07-27 by user (header chrome change included). Cleared for implementation.
Owner: PM a-20260725-036.
Scope strategy: **Option A** (per 2026-07-27 decision) — only the
model-independent subset of the Scan redesign. The rest of the Scan flow waits
for the window-based-reporting + event-first-wallet/binding model spec.

## 1. Scope

**IN scope**
- **New shared component — status pill**: a dot + label pill with two states,
  `Sensing automatically` (active) / `Sensing paused`. Added to
  `ios/Beid/DesignSystem.swift`, documented in `DESIGN.md §10`. This slice USES
  only the `Sensing automatically` state (on screen 05); the `paused` state is
  defined for later reuse (06d).
- **05 Scan / Sensing** (Figma node `104:168`) = `ios/Beid/Views/SensingView.swift`
  reskin: the status pill, the radar (concentric rings + center core/glyph), and
  the Figma body copy. Tokenize the currently-hardcoded `210×210` frame
  (`SensingView.swift:56`) and `BeidGlyph(..., size: 86)` — both are raw literals
  today and a `.swiftlint` blind spot (the `no_hardcoded_*` rules don't match
  `.frame(width:height:)`).
- **Scan modal header chrome** (`ios/Beid/Views/ScanFlowView.swift`): Figma's
  header — a `Scan` title + a trailing **close (X)** icon calling
  `coordinator.finishScan()` — replacing today's leading `Cancel` text button.
- **UI tests**: update/verify `ios/BeidUITests/BeidIPadLayoutTests.swift` (and
  sweep the test target) if they reference the changed scan chrome
  (`Cancel` → close X); keep them green.

**OUT of scope (deferred to the model spec / later slices)** — bodies unchanged
this slice, no behavior change:
- 06a Event Found (eventCard / venue), 06b Verifying, 06c Verified, 06d Signal
  Lost, 07 Proof Collected.
- Progress/verify/collect model, wallet-connect + binding, window/ENIN reporting,
  device event-signing-key wiring, real event/session model (venue field).

## 2. Source-of-truth precedence

Decision record > Figma > current code. App name **"Beid"**. `DESIGN.md` is the
token/design contract; the six scan views are already token-compliant reference
implementations (no migration debt) except the one untokenized size noted above.

## 3. Component & screen specs

### 3.1 Status pill (new shared component)
- Layout: leading dot + label text, in a pill. States:
  - `Sensing automatically` → active accent (`DS.Color.signalActive`).
  - `Sensing paused` → warning accent (`DS.Color.signalWarning`).
- Fully `DS.*`-token-driven (no literals), light/dark via xcassets, Dynamic Type.
- Documented in `DESIGN.md §10` (purpose / use-when / API / required tokens /
  accessibility), matching the existing §10 format.

### 3.2 05 Sensing (`SensingView.swift`, node 104:168)
- Status pill `Sensing automatically` near the top.
- Radar: concentric rings + center core/glyph per Figma; keep the existing
  entrance/pulse animation. Replace the raw `210×210` frame and `86` glyph size
  with new `BeidDesign.Size` (or `DS.Size`) tokens (e.g. `radarField`,
  `radarCore`).
- Body copy: **"Walk into an event — it will show up here automatically."**
  (Figma; replaces current "Keep beid open nearby to collect proof of
  attendance."). Localized per `AGENTS.md`.
- Exact colors/fonts/spacing pulled via `get_design_context` for `104:168` and
  mapped to `DS.*` tokens (add a new token only if genuinely needed:
  `Tokens.swift` + `Colors.xcassets` + `DESIGN.md §17`).
- `#Preview` light + dark.

### 3.3 Scan header chrome (`ScanFlowView.swift`)
- Header: `Scan` title + trailing **close (X)** icon button →
  `coordinator.finishScan()` (same action as today's Cancel). Token-compliant,
  matches Figma `104:168` header.
- Interim note: this shared chrome also renders on the not-yet-reskinned phases
  06a–07; their bodies stay unchanged this slice — acceptable interim state.

## 4. Acceptance criteria
- `xcodebuild -project ios/Beid.xcodeproj -scheme Beid -destination 'platform=iOS Simulator,name=iPhone 17 Pro' clean build` = BUILD SUCCEEDED.
- `scripts/lint.sh` = 0 violations; `SensingView`'s previously-untokenized
  `210×210` / `86` now use `DS`/`BeidDesign.Size` tokens.
- 05 matches Figma `104:168` (values via `get_design_context` → tokens).
- Status pill documented in `DESIGN.md §10`.
- `#Preview` present for `SensingView` (light + dark).
- UI tests pass (update `BeidIPadLayoutTests` if it referenced the old `Cancel`
  chrome; run with `-testLanguage en -testRegion US` — this sim defaults to
  Japanese).
- No behavior or body change to the deferred phases (only the shared header chrome).
- New/changed copy localized (ja/zh-Hans/es/fr `needs_review`) per `AGENTS.md`.
- PR-sized; no `.xcodeproj` hand-edits.

## 5. Deferred / next
- The rest of the Scan flow (06a–07) + wallet-connect/binding + window-based
  reporting await the **window-based-reporting + event-first-wallet/binding model
  spec** (Option C), which needs `beid#33` + the key list (to be shared by the user).

## 6. Branch note (for implementation time)
- Prefer basing this slice on `main` after PR #67 merges; if #67 is still open,
  stack on `feature/onboarding-redesign`. Decide at implementation time.
