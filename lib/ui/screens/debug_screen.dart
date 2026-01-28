import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/ble/ble_service.dart';
import '../../services/position/position_service.dart';
import '../../services/permission/permission_service.dart';
import '../../services/wallet/wallet_service.dart';
import '../widgets/detected_users_list.dart';
import 'raw_data_screen.dart';

/// デバッグ画面
class DebugScreen extends ConsumerWidget {
  const DebugScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bleState = ref.watch(bleServiceProvider);
    final walletState = ref.watch(walletServiceProvider);
    final permissionState = ref.watch(permissionServiceProvider);
    final positionState = ref.watch(positionServiceProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('デバッグ'),
        actions: [
          IconButton(
            icon: const Icon(Icons.data_array),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const RawDataScreen()),
              );
            },
            tooltip: 'ローデータ',
          ),
        ],
      ),
      body: Column(
        children: [
          // ステータス表示
          _buildStatusCard(context, ref, bleState, walletState, permissionState, positionState),

          // 検知ユーザー一覧
          Expanded(
            child: bleState.isSensing
                ? DetectedUsersList(detectedUsers: bleState.detectedUsers)
                : const _EmptyState(),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusCard(
    BuildContext context,
    WidgetRef ref,
    BleServiceState bleState,
    WalletServiceState walletState,
    PermissionServiceState permissionState,
    PositionServiceState positionState,
  ) {
    final statusColor = bleState.isSensing ? Colors.green : Colors.grey;
    final statusText = bleState.isSensing ? 'センシング中' : '停止中';
    final apiBaseUrl = dotenv.env['API_BASE_URL'] ?? '未設定';

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
            // コンパス設定
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.explore,
                      size: 18,
                      color: positionState.compassEnabled ? Colors.green : Colors.grey,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'コンパス補正',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
                Switch(
                  value: positionState.compassEnabled,
                  onChanged: (_) {
                    ref.read(positionServiceProvider.notifier).toggleCompass();
                  },
                ),
              ],
            ),
            if (positionState.compassEnabled && positionState.currentHeading != null)
              Padding(
                padding: const EdgeInsets.only(left: 26),
                child: Text(
                  '方位: ${positionState.currentHeading!.toStringAsFixed(1)}°',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.green,
                  ),
                ),
              ),
            const Divider(),
            // API設定
            Text(
              'API: $apiBaseUrl',
              style: Theme.of(context).textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              'WS: ${positionState.connectionState.name}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: positionState.connectionState == PositionConnectionState.connected
                    ? Colors.green
                    : null,
              ),
            ),
            Text(
              'Trilateration: ${positionState.trilaterationEnabled ? "有効 (${positionState.activeUsers}人)" : "無効"}',
              style: Theme.of(context).textTheme.bodySmall,
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
              'Event: ${bleState.isEventMode ? bleState.eventCode! : "Anonymous"}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: bleState.isEventMode ? const Color(0xFFFF6000) : null,
              ),
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
    final theme = Theme.of(context);
    final subtleColor = theme.colorScheme.onSurfaceVariant;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.bluetooth_searching,
            size: 80,
            color: subtleColor.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text(
            'センシングを開始してください',
            style: TextStyle(
              fontSize: 16,
              color: subtleColor,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'ウォレット接続後、ボタンをタップして\n近くのユーザーを検知できます',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: subtleColor.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}
