import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/ble/ble_service.dart';
import '../../services/permission/permission_service.dart';
import '../../services/wallet/wallet_service.dart';
import '../widgets/detected_users_list.dart';
import '../widgets/sensing_button.dart';
import '../widgets/wallet_button.dart';
import 'history_screen.dart';

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
    // ウォレットサービスを初期化
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(walletServiceProvider.notifier).initialize();
    });
  }

  Future<void> _handleSensingToggle() async {
    final walletState = ref.read(walletServiceProvider);
    final permissionState = ref.read(permissionServiceProvider);

    // ウォレット未接続の場合
    if (!walletState.isConnected) {
      _showSnackBar('ウォレットを接続してください');
      return;
    }

    // パーミッション未取得の場合
    if (!permissionState.allGranted) {
      final result =
          await ref.read(permissionServiceProvider.notifier).requestBlePermissions();
      result.fold(
        onSuccess: (_) {},
        onFailure: (error) {
          _showSnackBar(error.message);
          if (permissionState.anyPermanentlyDenied) {
            _showPermissionSettingsDialog();
          }
        },
      );
      return;
    }

    // センシングをトグル
    final bleService = ref.read(bleServiceProvider.notifier);
    final result = await bleService.toggleSensing();
    result.fold(
      onSuccess: (_) {},
      onFailure: (error) => _showSnackBar(error.message),
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

  @override
  Widget build(BuildContext context) {
    final bleState = ref.watch(bleServiceProvider);
    final walletState = ref.watch(walletServiceProvider);
    final permissionState = ref.watch(permissionServiceProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Beid'),
        actions: [
          WalletButton(
            walletState: walletState,
            onPressed: () async {
              if (walletState.isConnected) {
                await ref.read(walletServiceProvider.notifier).disconnect();
              } else {
                await ref
                    .read(walletServiceProvider.notifier)
                    .openModal(context);
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.history),
            onPressed: _navigateToHistory,
            tooltip: '履歴',
          ),
        ],
      ),
      body: Column(
        children: [
          // ステータス表示
          _buildStatusCard(bleState, walletState, permissionState),

          // 検知ユーザー一覧
          Expanded(
            child: bleState.isSensing
                ? DetectedUsersList(detectedUsers: bleState.detectedUsers)
                : const _EmptyState(),
          ),
        ],
      ),
      floatingActionButton: SensingButton(
        isSensing: bleState.isSensing,
        isLoading: bleState.sensingState == SensingState.starting ||
            bleState.sensingState == SensingState.stopping,
        onPressed: _handleSensingToggle,
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }

  Widget _buildStatusCard(BleServiceState bleState, WalletServiceState walletState, PermissionServiceState permissionState) {
    final statusColor = bleState.isSensing ? Colors.green : Colors.grey;
    final statusText = bleState.isSensing ? 'センシング中' : '停止中';

    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: statusColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        statusText,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      if (bleState.isSensing)
                        Text(
                          '検知数: ${bleState.detectedUsers.length}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
                if (bleState.bleState != BleState.poweredOn)
                  Chip(
                    label: const Text('BLE無効'),
                    backgroundColor: Colors.orange.shade100,
                  ),
              ],
            ),
            const Divider(),
            // デバッグ情報
            Text(
              'State: ${bleState.sensingState.name}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Text(
              'BLE: ${bleState.bleState.name}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Text(
              'Scan: ${bleState.isScanning}, Adv: ${bleState.isAdvertising}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Text(
              'Wallet: ${walletState.isConnected ? "接続中" : "未接続"}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Text(
              'Perm: BT=${permissionState.bluetoothStatus.name}, Loc=${permissionState.locationStatus.name}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.bluetooth_searching,
            size: 80,
            color: Colors.grey.shade400,
          ),
          const SizedBox(height: 16),
          Text(
            'センシングを開始してください',
            style: TextStyle(
              fontSize: 16,
              color: Colors.grey.shade600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'ウォレット接続後、ボタンをタップして\n近くのユーザーを検知できます',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey.shade500,
            ),
          ),
        ],
      ),
    );
  }
}
