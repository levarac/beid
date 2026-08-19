package org.levarac.beid.sensing

/**
 * Android-native mirror of iOS's `BeidConfig.eventConfirmThreshold`
 * (`ios/Beid/Models/BeidConfig.swift`). A plain data value fed as a
 * parameter into `org.levarac.beid.shared.sensing.applyScanDetection`'s pure
 * function — not a branch — so both platforms holding their own copy is
 * fine, same as iOS does. A value change here must be mirrored there, and
 * vice versa.
 */
object BeidConfig {
    const val eventConfirmThreshold: Int = 3
}
