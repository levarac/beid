// SPDX-License-Identifier: MIT

/// The two scan parameters `observe` must use, as values rather than as
/// literals buried in a CoreBluetooth call.
///
/// ## Why these are worth pinning
///
/// Both are load-bearing and both fail silently when wrong. chk-beid-590
/// showed the filter one directly: changing `withServices: [B001]` to
/// `withServices: nil` left the whole suite green and the no-connect guard
/// reporting `ok`. Nothing in the repository noticed, while the README argued
/// at length that the named filter is what makes backgrounded iOS phones
/// visible at all.
///
/// An instrument that quietly stops seeing the devices it was pointed at
/// produces "nobody was in the room" — the same failure class this tool was
/// built to prevent, arrived at from the other end.
///
/// `scripts/check_observe_never_connects.py` cross-checks `ObserveRunner`
/// against these values, so the constant and its use cannot drift apart.
public enum LabScanPolicy {
  /// Barnard's discovery service.
  ///
  /// Duplicated from `BarnardEngine.swift:283` at v0.9.2, where it is
  /// `private`. It is a wire value fixed by the protocol rather than a
  /// decision this repository gets to make — but a duplicated constant is
  /// still a constant that can go stale, and the symptom of staleness here is
  /// a run that sees nothing and reports cleanly.
  public static let discoveryServiceUUIDString = "0000B001-0000-1000-8000-00805F9B34FB"

  /// Why the filter is never `nil`.
  ///
  /// An iOS app advertising in the background moves its service UUID into the
  /// advertisement's overflow area, which CoreBluetooth surfaces **only** to a
  /// scan that names that UUID. A `nil` filter therefore misses exactly the
  /// backgrounded phones this is pointed at.
  public static let namedFilterRationale =
    "a nil filter misses backgrounded iOS advertisers, whose service UUID sits in the overflow area"

  /// Every advertisement, not one per peripheral.
  ///
  /// The repeat rate is this tool's decision (`--repeat-every`). With
  /// duplicates coalesced by the radio, the OS would decide when a peripheral
  /// looks quiet, and `peer_lost` — the actual measurement — would be
  /// reporting the scan's coalescing window rather than the air.
  public static let allowDuplicates = true
}
