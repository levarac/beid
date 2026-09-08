# Issue #339 — does DESIGN.md bind Android, or is iOS source-of-truth?

**Status:** decision-input for beid#339 (child of beid#335) only. This
document does not decide whether DESIGN.md binds Android; that is the
owner's decision. It also does not re-litigate #335's own decision (that
Android's screen structure and UI must match iOS completely, per #335's
own — Japanese-language — decision text, paraphrased here in translation,
not quoted) — it asks
a narrower, related question: is DESIGN.md itself, as a *document*,
binding on Android with the same MUST/FORBIDDEN weight it has on iOS, or
is it descriptive guidance Android moves toward while iOS remains the
enforced contract? The classification work in DESIGN.md itself (which
rules are platform-neutral, which have a named Android mechanism, which
are iOS-only as written) does **not** depend on the answer to this
question and has already landed as edits to DESIGN.md directly, per the
task brief for #339. Only the *bindingness* question is open, and it is
answered here as a recommendation only.

## What this decision gates

Nothing downstream is blocked on this decision in the sense of code that
cannot be written — Android UI work (beid#336/#337/#338) proceeds either
way, using DESIGN.md's now-annotated Android counterparts as the reference
either as enforced rule (Option A) or as guidance (Option B). What the
decision actually gates is **how a reviewer may treat a DESIGN.md
violation found in an Android PR**: as grounds to reject the PR the way an
iOS DESIGN.md violation already is (Option A), or as feedback that does
not by itself block merge (Option B). It also gates whether a future
Android-side lint/CI mechanism (parallel to `scripts/lint.sh`) is a
compliance gap to close or an optional convenience to build later.

## Option A — DESIGN.md binds both platforms as written

Once an Android counterpart is named for an iOS-specific mechanism (this
is now done, in DESIGN.md itself), Android is held to the same
MUST/FORBIDDEN weight iOS is. A DESIGN.md violation in an Android PR is
rejected on the same basis an iOS violation would be.

**Costs:**

- **A real enforcement gap, not just a lag.** DESIGN.md §16 (as amended)
  now states this precisely: iOS has `scripts/lint.sh` (SwiftLint) in PR
  CI covering §2 rules 1–4's "common surface forms... roughly the 80%
  case" (DESIGN.md §2, quoted), plus the author's own review for
  everything else. Android has **no lint mechanism at
  all** — no detekt, no ktlint, nothing — so under Option A, every single
  DESIGN.md rule on Android is enforced by nothing but the PR author's own
  review. Binding Android to the same MUST weight as iOS while only iOS
  has any automated check is not parity; it is a document that claims
  equal force while actually applying unequal pressure.
- **The repository has already lived this exact failure shape once, and
  said so out loud.** AGENTS.md's "Review gate — SUSPENDED as of
  2026-08-19" section states the reason for suspending the
  independent-review gate directly: across three consecutive PRs (#216,
  #221, #223) no independently dispatched reviewer was ever assigned while
  CI stayed green, and — quoting AGENTS.md verbatim — "A gate that is
  documented but never runs is worse than no gate, because it gets cited
  as though it were in force." A DESIGN.md that silently claims to bind
  Android with iOS's full weight, while only iOS has a lint gate and
  neither platform currently has independent review (the same suspended
  gate applies to both), is exactly this failure shape recurring at the
  document level instead of the review-process level. This is this
  repository's own precedent for the risk, not an argument imported from
  outside it.
- Reviewers must learn and apply Android-specific counterparts (Material
  Icons vs. SF Symbols, 48dp vs. 44pt hit targets, string resources vs.
  String Catalog) without tooling support, which is slower and more
  error-prone per PR than a lint-backed check.

**What Option A buys:** a single, unambiguous contract. No PR can argue
"DESIGN.md doesn't really apply to me" because it's on Android; every
violation is reviewable and, per beid#335's own stated intent, that
intent already treats Android UI drift as something to be corrected, not
tolerated as a lesser standard.

## Option B — iOS is source-of-truth; Android follows/adapts

DESIGN.md's Android counterparts are descriptive guidance Android moves
toward, not an enforced contract with the same weight as iOS's until
stated otherwise.

**Costs:**

- **Removes the pressure that would otherwise motivate building Android
  tooling.** If a DESIGN.md violation on Android is "guidance, not a
  blocker," there's no gate creating urgency to ever build the Android
  equivalent of `scripts/lint.sh`. The gap could become permanent by
  default rather than by decision — which is its own version of the same
  AGENTS.md lesson: an *unenforced* rule invites exactly the kind of
  drift beid#335 was filed to correct in the first place (recall: #335
  exists because Android's UI diverged badly with no document to point at
  as a violation — Option B keeps that document pointable-at but
  optional).
- Ambiguous authority in review: "should move toward" has no clear
  rejection threshold, so two reviewers could reasonably disagree on
  whether a given Android PR is close enough, reintroducing exactly the
  kind of undocumented, PR-by-PR scope judgment that produced #335's UI
  divergence.
- Undersells work already done: this pass names concrete Android
  mechanisms (e.g., `BeidTheme.colors.*`, `BeidNumberedStepList`'s
  ambient-tint-free API) with real, verified 1:1 fidelity to iOS in many
  places — treating all of that as "guidance" rather than "the rule"
  discounts work that already meets the bar.

**What Option B buys:** an honest acknowledgment that Android currently
has zero automated enforcement and — per beid#335's own scope note — some
Android surfaces are still mid-migration (no collection home, no icon
assets as of the last full verification) by *design decision* (deferred to
named follow-up issues, not neglect), so treating every gap as a rejection
predates the point where Android could plausibly comply. It also matches
today's *practice*, whatever this document decides: nobody has been
rejecting Android PRs against DESIGN.md, because DESIGN.md never named
Android before this pass.

## Recommendation

Recommend **Option A, once — and only once — the enforcement-asymmetry
cost above is treated as a tracked, named gap rather than left silent.**
The reasoning: #335's own decision text (Japanese; quoted verbatim, with
an unquoted English gloss immediately after) states
「Android の画面構造(ルート・phase 遷移・到達経路)と UI(コンポーネント・資産)を
iOS と完全に揃える」— Android's screen structure and UI are to be aligned
completely with iOS — and separately states 「『機能は揃ったが体験は別物』という
現状を許容しない」— the current state where functionality matches but the
experience doesn't is not acceptable. That severity argues for binding
weight, not descriptive guidance, once a rule has a named Android
mechanism to be held to. But recommending Option A without
naming the lint-coverage gap would repeat the review-gate mistake this
repository already made once (documented enforcement that doesn't run);
DESIGN.md §16 now states that gap explicitly for exactly this reason, and
whoever decides A vs. B should decide with that gap named, not discover it
later the way #216/#221/#223 discovered the review-gate gap.

**On #335 as input to this recommendation, stated precisely:** #335
establishes the owner's intent that Android's structure and UI match iOS —
it is real and load-bearing input here. It does **not**, however, settle
that Android always defers to iOS's *current* shape as the direction of
convergence. Verified concretely in this pass: `EventJoinScreen` already
offers automatic BLE-driven nearby-event discovery before manual code
entry, which iOS's current entry flow does not have — an area where
Android is presently ahead, not behind. #335's 完全に揃える ("align
completely") decision, quoted in full above, is best read as a
target-state parity goal, not a standing rule that every
difference resolves by Android conforming to whatever iOS does today. This
document does not decide how any specific divergence resolves (see #23
below) — only that #335 should not be read as pre-deciding that direction
in general.

## #24, #23, #104 — do they change meaning once Android is in scope?

Each issue's actual text was read (`gh issue view <n> --repo
thegreeting/beid`), not inferred from its title.

### #24 — §15 sentence-case ratification (still `PROPOSAL`)

**Verdict: partially changes meaning — the decision becomes richer, but
not the decision procedure itself.**

#24 asks Ken to pick one of three options (sentence case everywhere, Title
Case everywhere, or ratify the current grandfathered mix) and, once
decided, sweep all shipped CTA copy to match in one PR. Its own body
already anticipates Android: "Android (dispatch#4 配下) も同じ文言を使うので、
`android/app/src/main/res/values/strings.xml` の対応する英語文言を同時に揃える"
(quoted verbatim) — so the issue itself already scopes the eventual sweep
to include Android's `strings.xml`, prior to and independent of this
document's own scope work.

What #339 adds is a fact #24 didn't have when filed: **Android's shipped
CTA strings already mix casing the same way iOS's do**, verified directly
against `android/app/src/main/res/values/strings.xml` — Title Case ("Get
Started," "Open Settings," "Leave Event") alongside sentence case ("Join
event," "Enter event code"). Android has **no** string mirroring iOS's
specific "Sense Event" grandfather clause — its equivalent CTA is "Join
event," which is already sentence case, so Android has no CTA that is
currently grandfathered the way "Sense Event" is on iOS.

This changes the *scope* of the eventual sweep (there are now two
platforms' worth of strings to align in the single PR #24 already calls
for, not one) but does **not** change whether the ratification decision
needs to be made once for the document or once per platform: the rule
itself ("sentence case everywhere, including buttons") is a single English
copywriting-voice decision in §15, and #24's own body already treats it as
one decision applied to both platforms' string files in one sweep, not two
separate ratifications. Recommend the decision stay singular; Android
simply enlarges the sweep's file list, which #24 already anticipated.

### #23 — §11 rescue-path vs. `EventCodeEntryView`/`ManualEventCodeScreen`

**Verdict: changes meaning, in a way that needs new fact-gathering before
resolution, not a reused iOS answer.**

#23's actual text: `EventCodeEntryView` (landed in PR #21) is styled and
worded for onboarding (wallet-optional account setup), not for the
future sensing-failure rescue check-in §11 reserves; the issue's
acceptance criterion is only that whoever designs the eventual rescue path
records having checked the fit against `EventCodeEntryView` rather than
copying it blind, precisely because the context (onboarding vs. a
mid-sensing-failure moment) differs and the tone may need to differ too.

Verified fact this pass adds: Android already has its own manual
event-code screen, `ManualEventCodeScreen`/`ManualEventCodeRoute`
(`ui/screens/EventJoinScreen.kt`), reached only from `AccountScreen`'s
"Enter event code" button — not from onboarding, and not from the
scan-flow/recovery path. It sits at roughly the same role-and-naming
distance from a hypothetical Android rescue-path screen that
`EventCodeEntryView` sits from iOS's — i.e., #23's caution against reusing
a manual-entry screen's flow/copy without individually checking whether it
fits the rescue-path moment applies to a *second*, independently-built
screen now, not just to iOS's one.

What this document does **not** conclude, per explicit instruction from my
manager: it does not assume the eventual rescue-path resolution looks like
"Android's screen conforms to iOS's shape," and it does not decide which
of `EventCodeEntryView`/`ManualEventCodeScreen` (if either) the eventual
rescue path should be checked against first, or whether Android needs its
own separate check-fit exercise independent of iOS's. Bringing Android
into DESIGN.md's scope means #23's caution now has two onboarding/manual-
entry screens it could be mistakenly copied from instead of one — that is
the entire, narrow change in meaning. Recommend #23 be updated (by its
owner) to name both screens explicitly once this document lands, so a
future implementer checks fit against both rather than rediscovering that
Android has a second candidate.

### #104 — implementation doesn't match Figma

**Verdict: does not change meaning — stays scoped to iOS.**

#104's actual text is explicit that the Figma board (`Beid - Native`,
node `104-2`) and the six redesign slices it references (#67 onboarding,
#68 Scan Slice-1, #69 Account, #71 Collection, #72 ItemDetail, #75 Scan
Slice-2) are entirely iOS work — every named screen, slice, and row in
#104's own "intentional divergence" table (意図的な乖離, its own section
heading; e.g. the `SensingView` radar-background decision, the
`RecordingView` ceremony collapse, ItemDetail's "on-chain" prohibition)
cites iOS views and iOS specs (`docs/specs/*.md`) exclusively. Nothing in
#104 names or implies an Android target.

DESIGN.md §0 already frames the Figma board as "historical visual input,"
not authority, superseded by ratified redesign specs and the §§10–11
component/screen inventory — and per this pass's own new §0 annotation,
the Figma board itself is entirely iOS-only content (SwiftUI-era naming,
an iOS palette resolution against it). Bringing Android into DESIGN.md's
scope does not create a Figma-vs-Android comparison, because the Figma
board was never drawn against Android's UI in the first place — there is
no Android screen in the board to diverge from. #104's own three-way
triage plan (棚卸し→3分類, its own phrasing: intentional divergence /
implementation gap or drift / Figma is stale) stays exactly where it is:
an iOS-only reconciliation between iOS's shipped screens and an iOS-only
mock. Recommend no change to #104's scope or owner.
