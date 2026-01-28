import 'dart:math';

import 'package:flutter/material.dart';

import '../../../services/ble/ble_service.dart';
import '../../../services/position/position_service.dart';

/// レーダー描画用のCustomPainter
class RadarPainter extends CustomPainter {
  RadarPainter({
    required this.detectedUsers,
    required this.scanAngle,
    required this.primaryColor,
    required this.backgroundColor,
    this.serverPositions,
  });

  final Set<DetectedUser> detectedUsers;
  final double scanAngle; // 0-2π のスキャン線角度
  final Color primaryColor;
  final Color backgroundColor;
  /// サーバーから受信した位置情報（三点測位有効時のみ）
  final Map<String, UserPosition>? serverPositions;

  // RSSI範囲の定義
  static const double rssiMin = -90.0; // 遠い
  static const double rssiMax = -30.0; // 近い

  // デザイン定数
  static const int outerDotCount = 60;
  static const double outerDotRadius = 2.0;
  static const double cardinalMarkerLength = 20.0;
  static const double cardinalMarkerWidth = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = min(size.width, size.height) / 2 - 20;

    // 白い円形背景を描画
    _drawCircleBackground(canvas, center, maxRadius);

    // 内側の点線同心円を描画
    _drawDottedConcentricCircles(canvas, center, maxRadius);

    // 外周のドットリングを描画
    _drawOuterDotRing(canvas, center, maxRadius);

    // 基本方位のマーカーを描画（12, 3, 6, 9時位置）
    _drawCardinalMarkers(canvas, center, maxRadius);

    // スキャン針を描画
    _drawScanHands(canvas, center, maxRadius);

    // 中心点を描画
    _drawCenterPoint(canvas, center);

    // 検知ユーザーを描画
    _drawDetectedUsers(canvas, center, maxRadius);
  }

  void _drawCircleBackground(Canvas canvas, Offset center, double maxRadius) {
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    // 外周ドットより少し広めに背景を描画
    canvas.drawCircle(center, maxRadius + outerDotRadius + 6, paint);
  }

  void _drawDottedConcentricCircles(Canvas canvas, Offset center, double maxRadius) {
    final paint = Paint()
      ..color = primaryColor.withValues(alpha: 0.15)
      ..style = PaintingStyle.fill;

    // 3つの同心円（内側から25%, 50%, 75%の位置）
    for (int ring = 1; ring <= 3; ring++) {
      final radius = maxRadius * ring / 4;
      final dotCount = (24 * ring).clamp(24, 48); // 内側は少なく、外側は多く
      final dotRadius = 1.5;

      for (int i = 0; i < dotCount; i++) {
        final angle = (i / dotCount) * 2 * pi - pi / 2;
        final dotCenter = Offset(
          center.dx + radius * cos(angle),
          center.dy + radius * sin(angle),
        );
        canvas.drawCircle(dotCenter, dotRadius, paint);
      }
    }
  }

  void _drawOuterDotRing(Canvas canvas, Offset center, double maxRadius) {
    final paint = Paint()
      ..color = primaryColor.withValues(alpha: 0.4)
      ..style = PaintingStyle.fill;

    for (int i = 0; i < outerDotCount; i++) {
      // 12時位置から開始（-π/2 オフセット）
      final angle = (i / outerDotCount) * 2 * pi - pi / 2;
      final dotCenter = Offset(
        center.dx + maxRadius * cos(angle),
        center.dy + maxRadius * sin(angle),
      );

      // 基本方位（0, 15, 30, 45分位置）は少し大きく
      final isCardinal = i % 15 == 0;
      final radius = isCardinal ? outerDotRadius * 1.5 : outerDotRadius;

      canvas.drawCircle(dotCenter, radius, paint);
    }
  }

  void _drawCardinalMarkers(Canvas canvas, Offset center, double maxRadius) {
    final paint = Paint()
      ..color = primaryColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = cardinalMarkerWidth
      ..strokeCap = StrokeCap.round;

    // 12時、3時、6時、9時の4方向
    final cardinalAngles = [-pi / 2, 0, pi / 2, pi];

    for (final angle in cardinalAngles) {
      final innerRadius = maxRadius - cardinalMarkerLength - 8;
      final outerRadius = maxRadius - 8;

      final start = Offset(
        center.dx + innerRadius * cos(angle),
        center.dy + innerRadius * sin(angle),
      );
      final end = Offset(
        center.dx + outerRadius * cos(angle),
        center.dy + outerRadius * sin(angle),
      );

      canvas.drawLine(start, end, paint);
    }
  }

  void _drawScanHands(Canvas canvas, Offset center, double maxRadius) {
    // 3本の針を描画（120度間隔、同じ長さ）
    final handPaint = Paint()
      ..color = primaryColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;

    final handLength = maxRadius * 0.55;

    // 3本の針を120度間隔で描画
    for (int i = 0; i < 3; i++) {
      final angle = scanAngle - pi / 2 + (i * 2 * pi / 3);
      final handEnd = Offset(
        center.dx + handLength * cos(angle),
        center.dy + handLength * sin(angle),
      );
      canvas.drawLine(center, handEnd, handPaint);
    }
  }

  void _drawCenterPoint(Canvas canvas, Offset center) {
    // 中心の小さな点
    final paint = Paint()
      ..color = primaryColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, 4, paint);
  }

  // 解決済みユーザーのドット色（オレンジ）
  static const Color _resolvedUserColor = Color(0xFFFF6000);
  // 未解決ユーザーのドット色（グレー）
  static const Color _unresolvedUserColor = Color(0xFF999999);

  void _drawDetectedUsers(Canvas canvas, Offset center, double maxRadius) {
    for (final user in detectedUsers) {
      final position = _calculateUserPosition(user, center, maxRadius);
      final isResolved = user.resolvedDisplayId != null;
      final dotColor = isResolved ? _resolvedUserColor : _unresolvedUserColor;

      // メインの点
      final paint = Paint()
        ..color = dotColor
        ..style = PaintingStyle.fill;
      canvas.drawCircle(position, 6, paint);

      // 白い枠線
      final borderPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      canvas.drawCircle(position, 6, borderPaint);

      // 解決済みの場合は外側にリングを追加
      if (isResolved) {
        final ringPaint = Paint()
          ..color = _resolvedUserColor.withValues(alpha: 0.4)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5;
        canvas.drawCircle(position, 10, ringPaint);
      }
    }
  }

  Offset _calculateUserPosition(DetectedUser user, Offset center, double maxRadius) {
    double angle;
    double normalizedDistance;

    // サーバーから位置情報がある場合はそれを使用
    if (serverPositions != null && serverPositions!.containsKey(user.effectiveDisplayId)) {
      final serverPos = serverPositions![user.effectiveDisplayId]!;
      angle = serverPos.angle;
      normalizedDistance = serverPos.distance;
    } else {
      // フォールバック: スムージングされたRSSIから距離、displayIdから角度を計算
      normalizedDistance = _rssiToDistance(user.displayRssi);
      angle = _displayIdToAngle(user.effectiveDisplayId);
    }

    // 位置を計算（内側の領域に配置）
    final distance = normalizedDistance * maxRadius * 0.75;
    return Offset(
      center.dx + distance * cos(angle),
      center.dy + distance * sin(angle),
    );
  }

  double _rssiToDistance(int rssi) {
    // RSSIを0-1の距離に変換（近い=0, 遠い=1）
    final clampedRssi = rssi.clamp(rssiMin, rssiMax);
    return 1 - (clampedRssi - rssiMin) / (rssiMax - rssiMin);
  }

  double _displayIdToAngle(String displayId) {
    // displayIdのハッシュから角度を計算
    int hash = 0;
    for (int i = 0; i < displayId.length; i++) {
      hash = displayId.codeUnitAt(i) + ((hash << 5) - hash);
    }
    return (hash % 360) * pi / 180;
  }

  @override
  bool shouldRepaint(covariant RadarPainter oldDelegate) {
    return oldDelegate.detectedUsers != detectedUsers ||
        oldDelegate.scanAngle != scanAngle ||
        oldDelegate.serverPositions != serverPositions;
  }
}
