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

    return Padding(
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
    );
  }
}
