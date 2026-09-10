import Foundation

/// The version row's text, shared in shape with Android (beid#491).
///
/// Renders `{marketing} ({height}+{store})`, e.g. `1.0.0 (1234+374)`.
///
/// - `height` is the git height, injected into the bundle by
///   `ios/ci_scripts/ci_post_clone.sh`. It is a function of the built commit's
///   ancestry, so an iOS build and an Android build showing the same height were
///   built from the same commit. That is the only thing this number is for.
/// - `store` is `CFBundleVersion`, assigned by Xcode Cloud. It is the only
///   number App Store Connect, TestFlight and crash logs ever show, so it stays
///   in the row even when the height is absent.
///
/// When the height key is missing the height position reads `local` rather than
/// `0` or an empty string: a screenshot from a developer build must never be
/// mistakable for a delivered one. Presence of the key is what marks a bundle as
/// CI-produced, and the post-clone script is its only writer.
enum AppVersion {
  static let gitHeightInfoKey = "BeidGitHeight"
  static let localHeightPlaceholder = "local"

  static func displayString(bundle: Bundle = .main) -> String {
    let marketing = string(bundle, "CFBundleShortVersionString") ?? "0.0.0"
    let store = string(bundle, "CFBundleVersion") ?? "0"
    let height = string(bundle, gitHeightInfoKey) ?? localHeightPlaceholder
    return "\(marketing) (\(height)+\(store))"
  }

  /// Read as `String` on purpose. The plist key is written with an explicit
  /// `string` type; an `<integer>` would come back as `NSNumber` and this cast
  /// would fall through to the `local` branch while the bundle really did carry
  /// a height.
  private static func string(_ bundle: Bundle, _ key: String) -> String? {
    guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
          !value.isEmpty
    else { return nil }
    return value
  }
}
