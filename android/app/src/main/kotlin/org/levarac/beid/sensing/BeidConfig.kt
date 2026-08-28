package org.levarac.beid.sensing

import org.levarac.beid.shared.sensing.defaultEventConfirmThreshold

/**
 * Android-native mirror of iOS's `BeidConfig.eventConfirmThreshold`
 * (`ios/Beid/Models/BeidConfig.swift`). Both now read the same shared
 * constant (beid#231 item 3) — see
 * [org.levarac.beid.shared.sensing.defaultEventConfirmThreshold] for the
 * value's provenance and what it does not settle. Android has no
 * DEBUG/testing override of this value; that gap is accepted and out of
 * scope for #231 (see DECISIONS 2026-08-28).
 *
 * A plain `val`, not `const val`: this is a live read of the shared
 * constant, not a locally re-declared copy of its value, and a `val` makes
 * that unambiguous to a reader — a `const val` here would look identical to
 * the pre-#231 hardcoded duplicate this change removes.
 */
object BeidConfig {
    val eventConfirmThreshold: Int = defaultEventConfirmThreshold
}
