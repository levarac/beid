// Copyright (c) 2024-2026 Levarac Foundation
// SPDX-License-Identifier: MIT

import XCTest
@testable import Beid

@MainActor
final class SensingRadarViewTests: XCTestCase {
  private let size = DS.Size.radarField

  func testProjectionPreservesSilentNodeDimming() {
    let peers = [
      SensingRadarPeer(id: "fresh", signalStrength: .unmeasured),
      SensingRadarPeer(id: "silent", signalStrength: .unmeasured, isDimmed: true)
    ]
    let projection = SensingRadarProjection.project(peers, size: 362)
    XCTAssertEqual(projection.nodes.map(\.isDimmed), [false, true])
  }

  func testHashMatchesFrozenSigilVectors() {
    XCTAssertEqual(SensingRadarProjection.stablePeerHash("peer-a"), 0xb1df888881737297)
    XCTAssertEqual(SensingRadarProjection.stablePeerHash("a"), 0xaf63dc4c8601ec8c)
    XCTAssertEqual(SensingRadarProjection.stablePeerHash("日本語"), 0xee9ee2b5c854ef87)
    XCTAssertEqual(SensingRadarProjection.angleDegrees(for: "peer-a"), 71)
    XCTAssertEqual(SensingRadarProjection.angleDegrees(for: "peer-b"), 162)
    XCTAssertEqual(SensingRadarProjection.angleDegrees(for: "peer-c"), 253)
  }

  func testRingPathsMatchMeasuredFigmaDiameters() {
    let diameters = SensingRadarProjection.ringDiameters(size: size)
    XCTAssertEqual(diameters.count, 3)
    XCTAssertEqual(diameters[0], 133.22, accuracy: 0.001)
    XCTAssertEqual(diameters[1], 233.12, accuracy: 0.001)
    XCTAssertEqual(diameters[2], 333.04, accuracy: 0.001)
    XCTAssertEqual(DS.Size.radarCoreSeparation, 48)
    XCTAssertEqual(DS.Size.radarCore, 38)
    XCTAssertEqual(DS.Size.radarCenterDot, 8)
  }

  func testAngleAndDirectionStayFixedAcrossSignalChanges() {
    let first = SensingRadarProjection.project(
      [SensingRadarPeer(id: "peer-a", signalStrength: .unmeasured)],
      size: size
    ).nodes[0]
    let later = SensingRadarProjection.project(
      [SensingRadarPeer(id: "peer-a", signalStrength: .measured(dBm: -50))],
      size: size
    ).nodes[0]

    XCTAssertEqual(first.angleDegrees, later.angleDegrees)
    XCTAssertLessThan(later.radius, first.radius)
    let center = size / 2
    let firstDirection = CGPoint(x: (first.point.x - center) / first.radius,
                                 y: (first.point.y - center) / first.radius)
    let laterDirection = CGPoint(x: (later.point.x - center) / later.radius,
                                 y: (later.point.y - center) / later.radius)
    XCTAssertEqual(firstDirection.x, laterDirection.x, accuracy: 0.000_001)
    XCTAssertEqual(firstDirection.y, laterDirection.y, accuracy: 0.000_001)
  }

  func testUnmeasuredAndNeverMeasuredSentinelStayOutermost() {
    let outer = SensingRadarProjection.radius(for: .unmeasured, size: size)
    XCTAssertEqual(SensingRadarProjection.radius(for: .measured(dBm: 0), size: size), outer)
    XCTAssertEqual(SensingRadarProjection.radius(for: .measured(dBm: .infinity), size: size), outer)
    XCTAssertEqual(SensingRadarProjection.radius(for: .measured(dBm: -.infinity), size: size), outer)
    XCTAssertEqual(SensingRadarProjection.radius(for: .measured(dBm: -100), size: size), outer)
    XCTAssertLessThan(SensingRadarProjection.radius(for: .measured(dBm: -70), size: size), outer)
    XCTAssertLessThan(
      SensingRadarProjection.radius(for: .measured(dBm: -40), size: size),
      SensingRadarProjection.radius(for: .measured(dBm: -70), size: size)
    )
  }

  func testSignalBandsLandExactlyOnTheirRings() {
    let rings = SensingRadarProjection.ringDiameters(size: size).map { $0 / 2 }
    func radius(_ signal: NodeSignalStrength) -> CGFloat {
      SensingRadarProjection.radius(for: signal, size: size)
    }
    XCTAssertEqual(radius(.measured(dBm: -40)), rings[0])
    XCTAssertEqual(radius(.measured(dBm: -55)), rings[0])
    XCTAssertEqual(radius(.measured(dBm: -70)), rings[1])
    XCTAssertEqual(radius(.measured(dBm: -85)), rings[2])
    XCTAssertEqual(radius(.measured(dBm: -100)), rings[2])
    XCTAssertEqual(radius(.unmeasured), rings[2])
    XCTAssertEqual(radius(.measured(dBm: 0)), rings[2])
    XCTAssertEqual(radius(.measured(dBm: .nan)), rings[2])
    XCTAssertEqual(radius(.measured(dBm: 12)), rings[2])
  }

  func testEveryProjectedNodeSitsOnOneOfTheThreeRings() {
    let rings = SensingRadarProjection.ringDiameters(size: size).map { $0 / 2 }
    let signals: [NodeSignalStrength] = [
      .unmeasured, .measured(dBm: -40), .measured(dBm: -62), .measured(dBm: -70),
      .measured(dBm: -79), .measured(dBm: -90), .measured(dBm: -120), .measured(dBm: 0),
      .measured(dBm: .nan),
    ]
    let peers = signals.enumerated().map {
      SensingRadarPeer(id: "peer-\($0.offset)", signalStrength: $0.element)
    }
    let center = CGPoint(x: size / 2, y: size / 2)
    for node in SensingRadarProjection.project(peers, size: size).nodes {
      let distance = hypot(node.point.x - center.x, node.point.y - center.y)
      XCTAssertTrue(
        rings.contains { abs($0 - distance) < 0.000_1 },
        "\(node.peerID) at \(distance) is not on a ring"
      )
    }
  }

  func testEveryEdgeRunsFromMeToExactlyOnePeer() {
    let peers = [
      SensingRadarPeer(id: "peer-a", signalStrength: .unmeasured),
      SensingRadarPeer(id: "peer-b", signalStrength: .measured(dBm: -55)),
      SensingRadarPeer(id: "peer-c", signalStrength: .measured(dBm: -90)),
    ]
    let result = SensingRadarProjection.project(peers, size: size)
    let center = CGPoint(x: size / 2, y: size / 2)

    XCTAssertEqual(result.nodes.count, peers.count)
    XCTAssertEqual(result.edges.count, peers.count)
    XCTAssertEqual(Set(result.edges.map(\.peerID)), Set(peers.map(\.id)))
    for edge in result.edges {
      XCTAssertEqual(edge.from, center)
      XCTAssertEqual(edge.to, result.nodes.first { $0.peerID == edge.peerID }?.point)
      XCTAssertNotEqual(edge.to, center)
    }
  }

  func testDetectingOptionSuppressesEdgesButKeepsAllNodes() {
    let peers = [
      SensingRadarPeer(id: "peer-a", signalStrength: .unmeasured),
      SensingRadarPeer(id: "peer-b", signalStrength: .measured(dBm: -70)),
    ]
    let detecting = SensingRadarProjection.project(peers, size: size, showsEdges: false)
    let sensing = SensingRadarProjection.project(peers, size: size, showsEdges: true)

    XCTAssertEqual(detecting.nodes, sensing.nodes)
    XCTAssertTrue(detecting.edges.isEmpty)
    XCTAssertEqual(sensing.edges.count, peers.count)
  }

  func testAccessibilitySummaryOmitsMutualCountsAndPrivateIdentifiers() {
    let privateID = "private-peer-identifier"
    let peers = [
      SensingRadarPeer(id: privateID, signalStrength: .unmeasured),
      SensingRadarPeer(id: "other", signalStrength: .measured(dBm: -60)),
    ]
    let zeroSummary = SensingRadarProjection.accessibilitySummary(
      peers: peers,
      mutualDeviceCount: 0,
      observedWindowCount: 6
    )
    let mutualSummary = SensingRadarProjection.accessibilitySummary(
      peers: peers,
      mutualDeviceCount: 1,
      observedWindowCount: 6
    )

    XCTAssertEqual(zeroSummary, "2 devices heard in the last 5 minutes")
    XCTAssertEqual(mutualSummary, "2 devices heard in the last 5 minutes")
    XCTAssertEqual(
      SensingRadarProjection.accessibilitySummary(
        peers: Array(peers.prefix(1)), mutualDeviceCount: 0, observedWindowCount: 6),
      "1 device heard in the last 5 minutes")
    XCTAssertFalse(zeroSummary.contains(privateID))
    XCTAssertFalse(mutualSummary.contains(privateID))
    XCTAssertFalse(mutualSummary.contains("other"))
  }
}
