import 'package:flutter/material.dart';

import '../../services/ble/ble_service.dart';

/// 検知ユーザー一覧
class DetectedUsersList extends StatelessWidget {
  const DetectedUsersList({
    super.key,
    required this.detectedUsers,
  });

  final Set<DetectedUser> detectedUsers;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (detectedUsers.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              '近くのユーザーを検索中...',
              style: TextStyle(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    final sortedUsers = detectedUsers.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi)); // 信号強度順

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: sortedUsers.length,
      itemBuilder: (context, index) {
        final user = sortedUsers[index];
        return _DetectedUserTile(user: user);
      },
    );
  }
}

class _DetectedUserTile extends StatelessWidget {
  const _DetectedUserTile({required this.user});

  static const Color _accentColor = Color(0xFFFF6000);

  final DetectedUser user;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isResolved = user.resolvedDisplayId != null;
    final unresolvedColor = theme.brightness == Brightness.dark
        ? Colors.grey.shade600
        : Colors.grey;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: isResolved ? _accentColor : unresolvedColor,
          child: Icon(
            isResolved ? Icons.verified : Icons.person,
            color: Colors.white,
          ),
        ),
        title: Row(
          children: [
            Text(
              _formatDisplayId(user.effectiveDisplayId),
              style: const TextStyle(fontFamily: 'monospace'),
            ),
            if (isResolved) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: _accentColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  'ID',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: _accentColor,
                  ),
                ),
              ),
            ],
          ],
        ),
        subtitle: Text('最終検知: ${_formatTime(user.lastSeen)}'),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _SignalIndicator(rssi: user.rssi),
            Text(
              '${user.rssi} dBm',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  String _formatDisplayId(String displayId) {
    // displayIdは8文字の16進数なのでそのまま表示
    return displayId.toUpperCase();
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);

    if (diff.inSeconds < 5) {
      return 'たった今';
    } else if (diff.inSeconds < 60) {
      return '${diff.inSeconds}秒前';
    } else {
      return '${diff.inMinutes}分前';
    }
  }

}

class _SignalIndicator extends StatelessWidget {
  const _SignalIndicator({required this.rssi});

  final int rssi;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inactiveColor = theme.brightness == Brightness.dark
        ? Colors.grey.shade700
        : Colors.grey.shade300;

    // RSSIを0-4のバー数に変換
    // -90以下: 1バー, -80: 2バー, -70: 3バー, -60以上: 4バー
    final bars = ((-rssi - 50) ~/ 10).clamp(1, 4);
    final activeColor = _getColor(rssi);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(4, (index) {
        final isActive = index < (4 - bars + 1);
        return Container(
          width: 4,
          height: 8 + (index * 3).toDouble(),
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: isActive ? activeColor : inactiveColor,
            borderRadius: BorderRadius.circular(1),
          ),
        );
      }),
    );
  }

  Color _getColor(int rssi) {
    if (rssi >= -50) return Colors.green;
    if (rssi >= -70) return Colors.orange;
    return Colors.red;
  }
}
