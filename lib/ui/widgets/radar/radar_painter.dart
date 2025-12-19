import 'dart:math';

import 'package:flutter/material.dart';

import '../../../services/ble/ble_service.dart';

/// レーダー描画用のCustomPainter
class RadarPainter extends CustomPainter {
  RadarPainter({
    required this.detectedUsers,
    required this.scanAngle,
    required this.primaryColor,
    required this.backgroundColor,
  });

  final Set<DetectedUser> detectedUsers;
  final double scanAngle; // 0-2π のスキャン線角度
  final Color primaryColor;
  final Color backgroundColor;

  // RSSI範囲の定義
  static const double rssiMin = -90.0; // 遠い
  static const double rssiMax = -30.0; // 近い

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = min(size.width, size.height) / 2 - 20;

    // 背景を描画
    _drawBackground(canvas, center, maxRadius);

    // 同心円を描画
    _drawConcentricCircles(canvas, center, maxRadius);

    // スキャン線を描画
    _drawScanLine(canvas, center, maxRadius);

    // 中心点（自分）を描画
    _drawCenterPoint(canvas, center);

    // 検知ユーザーを描画
    _drawDetectedUsers(canvas, center, maxRadius);
  }

  void _drawBackground(Canvas canvas, Offset center, double maxRadius) {
    final paint = Paint()
      ..color = backgroundColor.withValues(alpha: 0.3)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, maxRadius, paint);
  }

  void _drawConcentricCircles(Canvas canvas, Offset center, double maxRadius) {
    final paint = Paint()
      ..color = primaryColor.withValues(alpha: 0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    // 4つの同心円を描画
    for (int i = 1; i <= 4; i++) {
      final radius = maxRadius * i / 4;
      canvas.drawCircle(center, radius, paint);
    }

    // 十字線を描画
    final crossPaint = Paint()
      ..color = primaryColor.withValues(alpha: 0.2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    canvas.drawLine(
      Offset(center.dx - maxRadius, center.dy),
      Offset(center.dx + maxRadius, center.dy),
      crossPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - maxRadius),
      Offset(center.dx, center.dy + maxRadius),
      crossPaint,
    );
  }

  void _drawScanLine(Canvas canvas, Offset center, double maxRadius) {
    // スキャン線のグラデーション
    final sweepGradient = SweepGradient(
      center: Alignment.center,
      startAngle: scanAngle - 0.5,
      endAngle: scanAngle,
      colors: [
        primaryColor.withValues(alpha: 0.0),
        primaryColor.withValues(alpha: 0.3),
      ],
      stops: const [0.0, 1.0],
      transform: GradientRotation(scanAngle - pi / 2),
    );

    final sweepPaint = Paint()
      ..shader = sweepGradient.createShader(
        Rect.fromCircle(center: center, radius: maxRadius),
      );

    canvas.drawCircle(center, maxRadius, sweepPaint);

    // スキャン線
    final linePaint = Paint()
      ..color = primaryColor.withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    final endPoint = Offset(
      center.dx + maxRadius * cos(scanAngle),
      center.dy + maxRadius * sin(scanAngle),
    );
    canvas.drawLine(center, endPoint, linePaint);
  }

  void _drawCenterPoint(Canvas canvas, Offset center) {
    // 外側の円
    final outerPaint = Paint()
      ..color = primaryColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;
    canvas.drawCircle(center, 12, outerPaint);

    // 内側の塗りつぶし
    final innerPaint = Paint()
      ..color = primaryColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, 6, innerPaint);
  }

  void _drawDetectedUsers(Canvas canvas, Offset center, double maxRadius) {
    for (final user in detectedUsers) {
      final position = _calculateUserPosition(user, center, maxRadius);
      final color = _getColorForRssi(user.rssi);

      // ユーザーの点を描画
      final paint = Paint()
        ..color = color
        ..style = PaintingStyle.fill;

      // グロー効果
      final glowPaint = Paint()
        ..color = color.withValues(alpha: 0.3)
        ..style = PaintingStyle.fill
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
      canvas.drawCircle(position, 12, glowPaint);

      // メインの点
      canvas.drawCircle(position, 8, paint);

      // 枠線
      final borderPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      canvas.drawCircle(position, 8, borderPaint);
    }
  }

  Offset _calculateUserPosition(DetectedUser user, Offset center, double maxRadius) {
    // RSSIから距離（0-1の範囲）を計算
    final normalizedDistance = _rssiToDistance(user.rssi);

    // displayIdからハッシュを生成して角度を決定（固定位置）
    final angle = _displayIdToAngle(user.displayId);

    // 位置を計算
    final distance = normalizedDistance * maxRadius * 0.9; // 外周の90%まで
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

  Color _getColorForRssi(int rssi) {
    // RSSIに応じた色を返す
    if (rssi >= -50) return Colors.green;
    if (rssi >= -70) return Colors.orange;
    return Colors.red;
  }

  @override
  bool shouldRepaint(covariant RadarPainter oldDelegate) {
    return oldDelegate.detectedUsers != detectedUsers ||
        oldDelegate.scanAngle != scanAngle;
  }
}
