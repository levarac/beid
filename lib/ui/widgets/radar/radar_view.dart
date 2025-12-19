import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/ble/ble_service.dart';
import '../../../services/position/position_service.dart';
import 'radar_painter.dart';

/// レーダービューウィジェット
class RadarView extends ConsumerStatefulWidget {
  const RadarView({super.key});

  @override
  ConsumerState<RadarView> createState() => _RadarViewState();
}

class _RadarViewState extends ConsumerState<RadarView>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bleState = ref.watch(bleServiceProvider);
    final positionState = ref.watch(positionServiceProvider);
    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;

    return Stack(
      children: [
        // レーダー表示エリア（タッチイベントを無視）
        Positioned.fill(
          child: IgnorePointer(
            child: Column(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: AnimatedBuilder(
                      animation: _animationController,
                      builder: (context, child) {
                        return CustomPaint(
                          painter: RadarPainter(
                            detectedUsers: bleState.detectedUsers,
                            scanAngle: _animationController.value * 2 * pi,
                            primaryColor: primaryColor,
                            backgroundColor: theme.colorScheme.surfaceContainerHighest,
                            serverPositions: positionState.trilaterationEnabled
                                ? positionState.positions
                                : null,
                          ),
                          size: Size.infinite,
                        );
                      },
                    ),
                  ),
                ),
                // 距離の凡例
                _buildLegend(context),
                // ステータスバー
                _buildStatusBar(context, bleState, positionState),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLegend(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _buildLegendItem(context, Colors.green, '近い (-50dBm以上)'),
          _buildLegendItem(context, Colors.orange, '中間 (-70〜-50dBm)'),
          _buildLegendItem(context, Colors.red, '遠い (-70dBm以下)'),
        ],
      ),
    );
  }

  Widget _buildLegendItem(BuildContext context, Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _buildStatusBar(BuildContext context, BleServiceState bleState, PositionServiceState positionState) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 80), // FAB用のスペースを確保
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: bleState.isSensing ? Colors.green : Colors.grey,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    bleState.isSensing ? 'センシング中' : '停止中',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
              Text(
                '検知数: ${bleState.detectedUsers.length}',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ],
          ),
          // 三点測位ステータス
          if (bleState.isSensing) ...[
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  positionState.trilaterationEnabled
                      ? Icons.gps_fixed
                      : Icons.gps_not_fixed,
                  size: 16,
                  color: positionState.trilaterationEnabled
                      ? Colors.green
                      : Colors.orange,
                ),
                const SizedBox(width: 4),
                Text(
                  positionState.trilaterationEnabled
                      ? '位置推定: 有効 (${positionState.activeUsers}人)'
                      : '位置推定: 3人以上で有効',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: positionState.trilaterationEnabled
                            ? Colors.green
                            : Colors.orange,
                      ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
