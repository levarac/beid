import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/ble/ble_service.dart';
import '../../services/device_id/device_id_service.dart';
import '../../services/permission/permission_service.dart';
import '../../services/position/position_service.dart';
import '../../services/wallet/wallet_service.dart';
import '../widgets/history_header_button.dart';
import '../widgets/my_page_header_button.dart';
import '../widgets/radar/radar_view.dart';
import '../widgets/sensing_button.dart';
import 'history_screen.dart';
import 'my_page_screen.dart';

/// ホーム画面
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  @override
  void initState() {
    super.initState();
    // デバイスIDとウォレットサービスを初期化
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(deviceIdServiceProvider.notifier).initialize();
      ref.read(walletServiceProvider.notifier).initialize();
    });
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
        if (!newBleState.isSensing) {
          positionService.disconnect();
        }
      },
      onFailure: (error) {
        _showSnackBar(error.message);
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

  void _navigateToHistory() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const HistoryScreen()),
    );
  }

  void _handleMyPageButtonPressed() async {
    final walletState = ref.read(walletServiceProvider);

    if (walletState.isConnected) {
      // ウォレット接続済み：マイページに遷移
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const MyPageScreen()),
      );
    } else {
      // ウォレット未接続：ウォレット接続モーダルを表示
      await ref.read(walletServiceProvider.notifier).openModal(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bleState = ref.watch(bleServiceProvider);
    final walletState = ref.watch(walletServiceProvider);

    return Scaffold(
      appBar: AppBar(
        leadingWidth: 64,
        leading: Padding(
          padding: const EdgeInsets.only(left: 16),
          child: HistoryHeaderButton(
            detectedCount: bleState.detectedUsers.length,
            onPressed: _navigateToHistory,
          ),
        ),
        title: null,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: MyPageHeaderButton(
              isWalletConnected: walletState.isConnected,
              onPressed: _handleMyPageButtonPressed,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          const Expanded(child: RadarView()),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: SensingButton(
              isSensing: bleState.isSensing,
              isLoading: bleState.sensingState == SensingState.starting ||
                  bleState.sensingState == SensingState.stopping,
              onPressed: _handleSensingToggle,
            ),
          ),
        ],
      ),
    );
  }
}
