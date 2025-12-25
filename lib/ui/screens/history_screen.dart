import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/sensing_record.dart';
import '../../data/repositories/sensing_repository.dart';
import 'debug_screen.dart';

/// 履歴画面
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final historyAsync = ref.watch(sensingHistoryProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('センシング履歴'),
        actions: [
          IconButton(
            icon: const Icon(Icons.bug_report_outlined),
            onPressed: () => _navigateToDebug(context),
            tooltip: 'デバッグ',
          ),
        ],
      ),
      body: historyAsync.when(
        data: (records) => records.isEmpty
            ? const _EmptyHistoryState()
            : _HistoryList(records: records),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('エラー: $error')),
      ),
    );
  }

  void _navigateToDebug(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const DebugScreen()),
    );
  }
}

class _EmptyHistoryState extends StatelessWidget {
  const _EmptyHistoryState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.history,
            size: 80,
            color: Colors.grey.shade400,
          ),
          const SizedBox(height: 16),
          Text(
            '履歴がありません',
            style: TextStyle(
              fontSize: 16,
              color: Colors.grey.shade600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'センシングを行うと\nここに履歴が表示されます',
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

class _HistoryList extends StatelessWidget {
  const _HistoryList({required this.records});

  final List<SensingRecord> records;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: records.length,
      itemBuilder: (context, index) {
        final record = records[index];
        return _HistoryTile(
          record: record,
          onTap: () => _showDetailSheet(context, record),
        );
      },
    );
  }

  void _showDetailSheet(BuildContext context, SensingRecord record) {
    showModalBottomSheet(
      context: context,
      builder: (context) => _RecordDetailSheet(record: record),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({
    required this.record,
    required this.onTap,
  });

  final SensingRecord record;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: _getStatusColor(record.status),
          child: Icon(
            _getStatusIcon(record.status),
            color: Colors.white,
            size: 20,
          ),
        ),
        title: Text(
          _formatUuid(record.partnerUuid),
          style: const TextStyle(fontFamily: 'monospace'),
        ),
        subtitle: Text(_formatDateTime(record.detectedAt)),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _StatusChip(status: record.status),
            Text(
              '${record.rssi} dBm',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  String _formatUuid(String uuid) {
    if (uuid.length > 16) {
      return '${uuid.substring(0, 8)}...${uuid.substring(uuid.length - 4)}';
    }
    return uuid;
  }

  String _formatDateTime(DateTime dateTime) {
    final now = DateTime.now();
    final diff = now.difference(dateTime);

    if (diff.inMinutes < 1) {
      return 'たった今';
    } else if (diff.inHours < 1) {
      return '${diff.inMinutes}分前';
    } else if (diff.inDays < 1) {
      return '${diff.inHours}時間前';
    } else if (diff.inDays < 7) {
      return '${diff.inDays}日前';
    } else {
      return '${dateTime.month}/${dateTime.day} ${dateTime.hour}:${dateTime.minute.toString().padLeft(2, '0')}';
    }
  }

  Color _getStatusColor(SensingStatus status) {
    return switch (status) {
      SensingStatus.detected => Colors.blue,
      SensingStatus.pending => Colors.orange,
      SensingStatus.verified => Colors.green,
      SensingStatus.poapIssued => Colors.purple,
      SensingStatus.failed => Colors.red,
    };
  }

  IconData _getStatusIcon(SensingStatus status) {
    return switch (status) {
      SensingStatus.detected => Icons.bluetooth_searching,
      SensingStatus.pending => Icons.hourglass_empty,
      SensingStatus.verified => Icons.check_circle,
      SensingStatus.poapIssued => Icons.card_giftcard,
      SensingStatus.failed => Icons.error,
    };
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final SensingStatus status;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: _getStatusColor(status).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        _getStatusText(status),
        style: TextStyle(
          fontSize: 12,
          color: _getStatusColor(status),
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  String _getStatusText(SensingStatus status) {
    return switch (status) {
      SensingStatus.detected => '検知',
      SensingStatus.pending => '検証中',
      SensingStatus.verified => '検証済',
      SensingStatus.poapIssued => 'POAP発行',
      SensingStatus.failed => '失敗',
    };
  }

  Color _getStatusColor(SensingStatus status) {
    return switch (status) {
      SensingStatus.detected => Colors.blue,
      SensingStatus.pending => Colors.orange,
      SensingStatus.verified => Colors.green,
      SensingStatus.poapIssued => Colors.purple,
      SensingStatus.failed => Colors.red,
    };
  }
}

class _RecordDetailSheet extends StatelessWidget {
  const _RecordDetailSheet({required this.record});

  final SensingRecord record;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: _getStatusColor(record.status),
                child: Icon(
                  _getStatusIcon(record.status),
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'センシング詳細',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    _StatusChip(status: record.status),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          _DetailRow(label: 'パートナーUUID', value: record.partnerUuid),
          _DetailRow(
            label: '検知日時',
            value: _formatFullDateTime(record.detectedAt),
          ),
          _DetailRow(label: 'RSSI', value: '${record.rssi} dBm'),
          if (record.txHash != null)
            _DetailRow(label: 'トランザクション', value: record.txHash!),
          if (record.errorMessage != null)
            _DetailRow(label: 'エラー', value: record.errorMessage!),
          const SizedBox(height: 16),
          if (record.status == SensingStatus.poapIssued)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  // TODO: POAPアプリへのディープリンク
                },
                icon: const Icon(Icons.open_in_new),
                label: const Text('POAPアプリで確認'),
              ),
            ),
        ],
      ),
    );
  }

  String _formatFullDateTime(DateTime dateTime) {
    return '${dateTime.year}/${dateTime.month}/${dateTime.day} '
        '${dateTime.hour}:${dateTime.minute.toString().padLeft(2, '0')}:'
        '${dateTime.second.toString().padLeft(2, '0')}';
  }

  Color _getStatusColor(SensingStatus status) {
    return switch (status) {
      SensingStatus.detected => Colors.blue,
      SensingStatus.pending => Colors.orange,
      SensingStatus.verified => Colors.green,
      SensingStatus.poapIssued => Colors.purple,
      SensingStatus.failed => Colors.red,
    };
  }

  IconData _getStatusIcon(SensingStatus status) {
    return switch (status) {
      SensingStatus.detected => Icons.bluetooth_searching,
      SensingStatus.pending => Icons.hourglass_empty,
      SensingStatus.verified => Icons.check_circle,
      SensingStatus.poapIssued => Icons.card_giftcard,
      SensingStatus.failed => Icons.error,
    };
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.grey.shade600,
                ),
          ),
          const SizedBox(height: 4),
          SelectableText(
            value,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontFamily: 'monospace',
                ),
          ),
        ],
      ),
    );
  }
}
