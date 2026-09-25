// Copyright 2024-2026 The Greeting Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license.

import Foundation
import SwiftUI

/// One display-only detected peer. `id` is the normalized, session-stable
/// display ID, not a rotating proximity ID. The caller supplies every
/// detected peer, including peers whose signal is still `.unmeasured`; the
/// coordinator's `nodeSignalStrengths` dictionary alone cannot supply them.
struct SensingRadarPeer: Identifiable, Equatable {
  let id: String
  let signalStrength: NodeSignalStrength
}

struct SensingRadarNode: Equatable {
  let peerID: String
  let point: CGPoint
  let angleDegrees: Int
  let radius: CGFloat
}

struct SensingRadarEdge: Equatable {
  let peerID: String
  let from: CGPoint
  let to: CGPoint
}

/// Provisional signal mapping; Figma fixes the drawing dimensions in DS.Size,
/// while real-device observation must settle these dBm display anchors.
private enum SensingRadarMetrics {
  static let coreClearance: CGFloat = 14
  static let outerInset: CGFloat = 12
  static let strongSignalDbm = -40.0
  static let weakSignalDbm = -100.0
}

/// Pure, small projection for the SwiftUI renderer and geometry tests.
/// Distances are display-only and never reach a record or submission path.
enum SensingRadarProjection {
  static func scale(for size: CGFloat) -> CGFloat {
    size / DS.Size.radarField
  }

  /// The three SVG circle path diameters, scaled together if a caller uses a
  /// different field size. At 362 pt these are 133.22, 233.12, and 333.04.
  static func ringDiameters(size: CGFloat) -> [CGFloat] {
    let scale = scale(for: size)
    return [DS.Size.radarRingInner, DS.Size.radarRingMiddle, DS.Size.radarRingOuter]
      .map { $0 * scale }
  }

  /// FNV-1a 64 over UTF-8, matching `sigilPeerHash` in shared's
  /// `SigilLayout.kt`. Swift's `hashValue` is process-seeded and would rotate
  /// every peer between launches. The caller must pass a stable normalized ID.
  static func stablePeerHash(_ peerID: String) -> UInt64 {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in peerID.utf8 {
      hash = (hash ^ UInt64(byte)) &* 0x100000001b3
    }
    return hash
  }

  static func angleDegrees(for peerID: String) -> Int {
    Int(stablePeerHash(peerID) % 360)
  }

  /// Stronger measured signals sit nearer the core. An unmeasured peer sits
  /// outermost. Defensive handling of 0 and non-finite values ensures a
  /// malformed producer cannot turn Barnard's never-measured sentinel into
  /// a claim of proximity. The -40/-100 display anchors are provisional,
  /// not hardware-verified calibration.
  static func radius(for signal: NodeSignalStrength, size: CGFloat) -> CGFloat {
    let scale = scale(for: size)
    let inner = (DS.Size.radarCoreSeparation / 2 + SensingRadarMetrics.coreClearance) * scale
    let outer = max(inner, size / 2 - SensingRadarMetrics.outerInset * scale)
    guard case let .measured(dBm) = signal, dBm.isFinite, dBm < 0 else {
      return outer
    }
    let fraction = min(max(
      (SensingRadarMetrics.strongSignalDbm - dBm)
        / (SensingRadarMetrics.strongSignalDbm - SensingRadarMetrics.weakSignalDbm),
      0
    ), 1)
    return inner + (outer - inner) * CGFloat(fraction)
  }

  static func project(_ peers: [SensingRadarPeer], size: CGFloat, showsEdges: Bool = true) -> (
    nodes: [SensingRadarNode], edges: [SensingRadarEdge]
  ) {
    let center = CGPoint(x: size / 2, y: size / 2)
    let nodes = peers.map { peer in
      let angle = angleDegrees(for: peer.id)
      let radians = Double(angle) * .pi / 180
      let radius = radius(for: peer.signalStrength, size: size)
      return SensingRadarNode(
        peerID: peer.id,
        point: CGPoint(
          x: center.x + CGFloat(sin(radians)) * radius,
          y: center.y - CGFloat(cos(radians)) * radius
        ),
        angleDegrees: angle,
        radius: radius
      )
    }
    // 05a/05a2/05a3 show detected nodes without edges. When enabled, each
    // edge starts at me; there is no peer-to-peer edge API.
    let edges = showsEdges
      ? nodes.map { SensingRadarEdge(peerID: $0.peerID, from: center, to: $0.point) }
      : []
    return (nodes, edges)
  }

  /// Mutuality is the caller's real `SessionAggregate.mutualDeviceCount`, not
  /// inferred from the detected-only drawing. A value of zero is spoken.
  /// Never speak or expose private peer IDs.
  static func accessibilitySummary(
    peers: [SensingRadarPeer],
    mutualDeviceCount: Int,
    observedWindowCount: Int
  ) -> String {
    String(
      localized: "sensingRadar.accessibilitySummary",
      defaultValue: "\(mutualDeviceCount) mutual, \(peers.count) detected, window \(observedWindowCount)",
      comment: "VoiceOver summary of the sensing radar. The first count comes from the real session aggregate and may be zero; detected counts the drawn peers; window is the aggregate's observed-window count, including an open first window. No peer identifier is spoken. Mutuality does not determine any individual node's style."
    )
  }
}

/// A reusable sensing-time radar. `peers` must include unmeasured detections;
/// use `SensingCoordinator.signalStrength(forNodeId:)` for each ID. The caller
/// supplies `mutualDeviceCount` from `SessionAggregate.mutualDeviceCount` and
/// `observedWindowCount` from the aggregate's observed windows. Neither count
/// changes node styling. The field defaults to the Figma 05 diameter.
struct SensingRadarView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let peers: [SensingRadarPeer]
  let mutualDeviceCount: Int
  let observedWindowCount: Int
  let showsEdges: Bool
  let size: CGFloat

  init(
    peers: [SensingRadarPeer],
    mutualDeviceCount: Int,
    observedWindowCount: Int,
    showsEdges: Bool = true,
    size: CGFloat = DS.Size.radarField
  ) {
    self.peers = peers
    self.mutualDeviceCount = mutualDeviceCount
    self.observedWindowCount = observedWindowCount
    self.showsEdges = showsEdges
    self.size = size
  }

  var body: some View {
    let projection = SensingRadarProjection.project(peers, size: size, showsEdges: showsEdges)
    let scale = SensingRadarProjection.scale(for: size)
    ZStack {
      ForEach(SensingRadarProjection.ringDiameters(size: size), id: \.self) { diameter in
        Circle()
          .stroke(DS.Color.strokeHairlineOnInk, lineWidth: DS.Size.hairline)
          .frame(width: diameter, height: diameter)
      }

      ForEach(projection.edges, id: \.peerID) { edge in
        SensingRadarEdgeShape(endpoint: edge.to)
          .stroke(DS.Color.strokeHairlineOnInk, lineWidth: DS.Size.hairline)
          .frame(width: size, height: size)
          .animation(reduceMotion ? nil : DS.Motion.standard, value: edge.to)
      }

      // Measured from Figma 05: 48 pt ink separation, 38 pt white disc,
      // 8 pt ink centre dot, scaled with the field.
      Circle()
        .fill(DS.Color.textPrimary)
        .frame(width: DS.Size.radarCoreSeparation * scale,
               height: DS.Size.radarCoreSeparation * scale)
        .overlay {
          Circle()
            .fill(DS.Color.surfaceCanvas)
            .frame(width: DS.Size.radarCore * scale, height: DS.Size.radarCore * scale)
            .overlay {
              Circle()
                .fill(DS.Color.textPrimary)
                .frame(width: DS.Size.radarCenterDot * scale,
                       height: DS.Size.radarCenterDot * scale)
            }
        }

      ForEach(projection.nodes, id: \.peerID) { node in
        detectedGlyph(scale: scale)
          .position(node.point)
          .animation(reduceMotion ? nil : DS.Motion.standard, value: node.point)
      }
    }
    .frame(width: size, height: size)
    .background(DS.Color.textPrimary)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(SensingRadarProjection.accessibilitySummary(
      peers: peers,
      mutualDeviceCount: mutualDeviceCount,
      observedWindowCount: observedWindowCount
    )))
    .accessibilityIdentifier("sensing.radar")
  }

  /// Figma 05's detected-only mark: ink fill and idle outline. The aggregate
  /// mutual count does not identify which drawn peer was mutual, so no node
  /// receives mutual or confirmed styling.
  private func detectedGlyph(scale: CGFloat) -> some View {
    Circle()
      .fill(DS.Color.textPrimary)
      .overlay {
        Circle()
          .stroke(DS.Color.graphNodeIdle, lineWidth: DS.Size.radarDetectedNodeStroke * scale)
      }
      .frame(width: DS.Size.radarDetectedNode * scale,
             height: DS.Size.radarDetectedNode * scale)
  }
}

/// Animates edge endpoints with node movement. Its path always begins at the
/// radar centre; no caller can construct a peer-to-peer segment with it.
private struct SensingRadarEdgeShape: Shape {
  var endpoint: CGPoint

  var animatableData: AnimatablePair<CGFloat, CGFloat> {
    get { AnimatablePair(endpoint.x, endpoint.y) }
    set { endpoint = CGPoint(x: newValue.first, y: newValue.second) }
  }

  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.midX, y: rect.midY))
    path.addLine(to: endpoint)
    return path
  }
}
