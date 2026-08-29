package org.levarac.beid.shared.sensing

/**
 * The distinct-device count that confirms an event — beid#231 item 3.
 *
 * This moves *where* an already-decided number lives, not a new product
 * decision: DECISIONS 2026-07-30 (D3) fixed the threshold at `3` for v1 and
 * explicitly deferred a per-event/organizer-configurable value to the
 * future. Before this, iOS and Android each held their own copy of the same
 * literal `3` (beid#231's items 1/2 moved the two device-counting rules that
 * consume it; this is the third and last duplicated input to
 * [applyScanDetection]).
 *
 * This does **not** settle what happens when beid#108 (`EventDefinition/v1`
 * via `EventRegistry`) lands and a real per-event value becomes suppliable:
 * the precedence rule between this default and a per-event override is its
 * own new decision, and this constant neither preempts nor blocks it. #108
 * is currently open, and [org.levarac.beid.shared.event.EventDefinitionFacts]
 * carries no threshold field today.
 *
 * Native DEBUG/testing overrides (iOS's
 * `eventConfirmThresholdOverrideForTesting` and the
 * `-beid-threshold-override` launch argument) remain entirely native — they
 * wrap this constant, they do not replace it, and they stay unreachable in
 * Release exactly as before. Android has no such override; that gap is
 * accepted and out of scope here (see DECISIONS 2026-08-28).
 */
public const val defaultEventConfirmThreshold: Int = 3
