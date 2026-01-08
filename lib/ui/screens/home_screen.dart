import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/ble/ble_service.dart';
import '../../services/device_id/device_id_service.dart';
import '../../services/permission/permission_service.dart';
import '../../services/position/position_service.dart';
import '../../services/wallet/wallet_service.dart';
import '../widgets/radar/radar_view.dart';
import '../widgets/sensing_button.dart';

/// ホーム画面
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  DateTime? _sensingStartTime;
  Timer? _elapsedTimer;
  Duration _elapsedDuration = Duration.zero;

  @override
  void initState() {
    super.initState();
    // デバイスIDとウォレットサービスを初期化
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(deviceIdServiceProvider.notifier).initialize();
      ref.read(walletServiceProvider.notifier).initialize();
    });
  }

  @override
  void dispose() {
    _elapsedTimer?.cancel();
    super.dispose();
  }

  void _startElapsedTimer() {
    _sensingStartTime = DateTime.now();
    _elapsedDuration = Duration.zero;
    _elapsedTimer?.cancel();
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_sensingStartTime != null) {
        setState(() {
          _elapsedDuration = DateTime.now().difference(_sensingStartTime!);
        });
      }
    });
  }

  void _stopElapsedTimer() {
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
    _sensingStartTime = null;
    setState(() {
      _elapsedDuration = Duration.zero;
    });
  }

  String _formatElapsedTime(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (duration.inHours > 0) {
      final hours = duration.inHours.toString().padLeft(2, '0');
      return '$hours:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  Future<void> _handleSensingToggle() async {
    final deviceIdState = ref.read(deviceIdServiceProvider);
    final permissionState = ref.read(permissionServiceProvider);

    // デバイスIDが初期化されていない場合
    if (!deviceIdState.isInitialized || deviceIdState.deviceId == null) {
      _showSnackBar('デバイスIDの初期化中です。しばらくお待ちください。');
      return;
    }

    // パーミッション未取得の場合
    if (!permissionState.allGranted) {
      final result =
          await ref.read(permissionServiceProvider.notifier).requestBlePermissions();

      final permissionGranted = result.fold(
        onSuccess: (_) => true,
        onFailure: (error) {
          _showSnackBar(error.message);
          if (permissionState.anyPermanentlyDenied) {
            _showPermissionSettingsDialog();
          }
          return false;
        },
      );

      if (!permissionGranted) {
        return;
      }
      // パーミッション許可後、センシングに進む
    }

    // センシングをトグル
    final bleService = ref.read(bleServiceProvider.notifier);
    final bleState = ref.read(bleServiceProvider);
    final positionService = ref.read(positionServiceProvider.notifier);

    // センシング開始前にWebSocket接続を開始
    if (!bleState.isSensing) {
      // センシング開始時：WebSocket接続（デバイスIDを使用）
      final displayId = deviceIdState.shortId ?? 'unknown';
      await positionService.connect(displayId);
    }

    final result = await bleService.toggleSensing();
    result.fold(
      onSuccess: (_) {
        // センシング停止時：WebSocket切断
        final newBleState = ref.read(bleServiceProvider);
        if (newBleState.isSensing) {
          _startElapsedTimer();
        } else {
          _stopElapsedTimer();
          positionService.disconnect();
        }
      },
      onFailure: (error) {
        _showSnackBar(error.message);
        _stopElapsedTimer();
        // エラー時もWebSocket切断
        positionService.disconnect();
      },
    );
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _showPermissionSettingsDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('パーミッションが必要です'),
        content: const Text('設定画面からBluetoothと位置情報のパーミッションを許可してください。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              // openAppSettings(); // permission_handlerの関数
            },
            child: const Text('設定を開く'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bleState = ref.watch(bleServiceProvider);

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Column(
                children: [
                  const SizedBox(height: 48),
                  // 検知数
                  Text(
                    '${bleState.detectedUsers.length}',
                    style: const TextStyle(
                      fontFamily: 'Silkscreen',
                      fontSize: 72,
                      fontWeight: FontWeight.w400,
                      height: 1,
                    ),
                  ),
                  const Expanded(child: RadarView()),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              child: SensingButton(
                isSensing: bleState.isSensing,
                isLoading: bleState.sensingState == SensingState.starting ||
                    bleState.sensingState == SensingState.stopping,
                onPressed: _handleSensingToggle,
                elapsedTime: bleState.isSensing ? _formatElapsedTime(_elapsedDuration) : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
