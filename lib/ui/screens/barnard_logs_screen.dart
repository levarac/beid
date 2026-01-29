import 'dart:async';

import 'package:barnard/barnard.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/ble/ble_service.dart';

/// ログエントリ
class BarnardLogEntry {
  BarnardLogEntry({
    required this.timestamp,
    required this.type,
    required this.message,
    this.details,
    this.level = LogLevel.info,
  });

  final DateTime timestamp;
  final String type;
  final String message;
  final Map<String, dynamic>? details;
  final LogLevel level;
}

enum LogLevel { trace, info, warn, error }

/// Barnardログ状態
class BarnardLogsState {
  const BarnardLogsState({
    this.logs = const [],
    this.isSubscribed = false,
  });

  final List<BarnardLogEntry> logs;
  final bool isSubscribed;

  BarnardLogsState copyWith({
    List<BarnardLogEntry>? logs,
    bool? isSubscribed,
  }) {
    return BarnardLogsState(
      logs: logs ?? this.logs,
      isSubscribed: isSubscribed ?? this.isSubscribed,
    );
  }
}

/// Barnardログ Notifier
class BarnardLogsNotifier extends StateNotifier<BarnardLogsState> {
  BarnardLogsNotifier(this._ref) : super(const BarnardLogsState());

  final Ref _ref;
  static const int maxLogs = 500;
  StreamSubscription<BarnardEvent>? _eventSubscription;
  StreamSubscription<BarnardDebugEvent>? _debugSubscription;

  void startListening() {
    if (state.isSubscribed) return;

    try {
      final bleNotifier = _ref.read(bleServiceProvider.notifier);
      final client = bleNotifier.client;

      if (client == null) {
        _addLog(BarnardLogEntry(
          timestamp: DateTime.now(),
          type: 'SYSTEM',
          message: 'Client not initialized yet',
          level: LogLevel.warn,
        ));
        return;
      }

      // メインイベントストリームをサブスクライブ
      _eventSubscription = client.events.listen(
        _onBarnardEvent,
        onError: (error) {
          _addLog(BarnardLogEntry(
            timestamp: DateTime.now(),
            type: 'ERROR',
            message: 'Event stream error: $error',
            level: LogLevel.error,
          ));
        },
      );

      // デバッグイベントストリームをサブスクライブ（存在する場合のみ）
      try {
        _debugSubscription = client.debugEvents.listen(
          _onDebugEvent,
          onError: (error) {
            _addLog(BarnardLogEntry(
              timestamp: DateTime.now(),
              type: 'ERROR',
              message: 'Debug stream error: $error',
              level: LogLevel.error,
            ));
          },
        );
      } catch (e) {
        _addLog(BarnardLogEntry(
          timestamp: DateTime.now(),
          type: 'SYSTEM',
          message: 'Debug events not available: $e',
          level: LogLevel.warn,
        ));
      }

      state = state.copyWith(isSubscribed: true);

      _addLog(BarnardLogEntry(
        timestamp: DateTime.now(),
        type: 'SYSTEM',
        message: 'Log subscription started',
        level: LogLevel.info,
      ));
    } catch (e) {
      _addLog(BarnardLogEntry(
        timestamp: DateTime.now(),
        type: 'ERROR',
        message: 'Failed to start listening: $e',
        level: LogLevel.error,
      ));
    }
  }

  void stopListening() {
    _eventSubscription?.cancel();
    _eventSubscription = null;
    _debugSubscription?.cancel();
    _debugSubscription = null;
    state = state.copyWith(isSubscribed: false);
  }

  @override
  void dispose() {
    stopListening();
    super.dispose();
  }

  void _onBarnardEvent(BarnardEvent event) {
    try {
      final entry = switch (event) {
        DetectionEvent() => BarnardLogEntry(
            timestamp: event.timestamp,
            type: 'DETECTION',
            message:
                'Detected: ${event.displayId} (RSSI: ${event.rssi}dBm)${event.isResolved ? " [RESOLVED: ${event.resolvedDisplayId}]" : ""}',
            details: {
              'displayId': event.displayId,
              'rssi': event.rssi,
              'transport': event.transport.toString(),
              'formatVersion': event.formatVersion,
              'isResolved': event.isResolved,
              'resolvedDisplayId': event.resolvedDisplayId,
              'debugLocalName': event.debugLocalName,
              if (event.rssiSummary != null) ...{
                'rssiCount': event.rssiSummary!.count,
                'rssiMin': event.rssiSummary!.min,
                'rssiMax': event.rssiSummary!.max,
                'rssiMean': event.rssiSummary!.mean,
              },
            },
            level: LogLevel.info,
          ),
        RssiUpdateEvent() => BarnardLogEntry(
            timestamp: event.timestamp,
            type: 'RSSI_UPDATE',
            message:
                'RSSI: ${event.displayId} -> ${event.rssi}dBm${event.resolvedDisplayId != null ? " [${event.resolvedDisplayId}]" : ""}',
            details: {
              'displayId': event.displayId,
              'rssi': event.rssi,
              'resolvedDisplayId': event.resolvedDisplayId,
            },
            level: LogLevel.trace,
          ),
        StateEvent() => BarnardLogEntry(
            timestamp: event.timestamp,
            type: 'STATE',
            message:
                'State: scan=${event.state.isScanning}, adv=${event.state.isAdvertising}${event.reasonCode != null ? " (${event.reasonCode})" : ""}',
            details: {
              'isScanning': event.state.isScanning,
              'isAdvertising': event.state.isAdvertising,
              'reasonCode': event.reasonCode,
            },
            level: LogLevel.info,
          ),
        ConstraintEvent() => BarnardLogEntry(
            timestamp: event.timestamp,
            type: 'CONSTRAINT',
            message: 'Constraint: ${event.code}${event.message != null ? " - ${event.message}" : ""}',
            details: {
              'code': event.code,
              'message': event.message,
              'requiredAction': event.requiredAction,
            },
            level: LogLevel.warn,
          ),
        ErrorEvent() => BarnardLogEntry(
            timestamp: event.timestamp,
            type: 'ERROR',
            message: 'Error: ${event.code} - ${event.message}',
            details: {
              'code': event.code,
              'message': event.message,
              'recoverable': event.recoverable,
            },
            level: LogLevel.error,
          ),
      };

      _addLog(entry);
    } catch (e) {
      _addLog(BarnardLogEntry(
        timestamp: DateTime.now(),
        type: 'ERROR',
        message: 'Failed to parse event: $e (${event.runtimeType})',
        level: LogLevel.error,
      ));
    }
  }

  void _onDebugEvent(BarnardDebugEvent event) {
    try {
      final level = switch (event.level) {
        DebugLevel.trace => LogLevel.trace,
        DebugLevel.info => LogLevel.info,
        DebugLevel.warn => LogLevel.warn,
        DebugLevel.error => LogLevel.error,
      };

      Map<String, dynamic>? details;
      try {
        details = event.data != null
            ? Map<String, dynamic>.from(event.data!)
            : null;
      } catch (_) {
        details = {'raw': event.data.toString()};
      }

      _addLog(BarnardLogEntry(
        timestamp: event.timestamp,
        type: 'DEBUG',
        message: event.name,
        details: details,
        level: level,
      ));
    } catch (e) {
      _addLog(BarnardLogEntry(
        timestamp: DateTime.now(),
        type: 'ERROR',
        message: 'Failed to parse debug event: $e',
        level: LogLevel.error,
      ));
    }
  }

  void _addLog(BarnardLogEntry entry) {
    final newLogs = [entry, ...state.logs];
    if (newLogs.length > maxLogs) {
      state = state.copyWith(logs: newLogs.sublist(0, maxLogs));
    } else {
      state = state.copyWith(logs: newLogs);
    }
  }

  void clearLogs() {
    state = state.copyWith(logs: []);
  }

  void addManualLog(String message) {
    _addLog(BarnardLogEntry(
      timestamp: DateTime.now(),
      type: 'MANUAL',
      message: message,
      level: LogLevel.info,
    ));
  }
}

/// Barnardログプロバイダー
final barnardLogsProvider =
    StateNotifierProvider<BarnardLogsNotifier, BarnardLogsState>((ref) {
  return BarnardLogsNotifier(ref);
});

/// Barnardログ画面
class BarnardLogsScreen extends ConsumerStatefulWidget {
  const BarnardLogsScreen({super.key});

  @override
  ConsumerState<BarnardLogsScreen> createState() => _BarnardLogsScreenState();
}

class _BarnardLogsScreenState extends ConsumerState<BarnardLogsScreen> {
  bool _showTrace = false;
  bool _autoScroll = true;
  String _filterType = 'ALL';
  final ScrollController _scrollController = ScrollController();

  static const List<String> _filterOptions = [
    'ALL',
    'DETECTION',
    'RSSI_UPDATE',
    'STATE',
    'ERROR',
    'DEBUG',
  ];

  @override
  void initState() {
    super.initState();
    // 画面表示時にリスニング開始
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(barnardLogsProvider.notifier).startListening();
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final logsState = ref.watch(barnardLogsProvider);
    final bleState = ref.watch(bleServiceProvider);

    // フィルタリング
    final filteredLogs = logsState.logs.where((log) {
      if (!_showTrace && log.level == LogLevel.trace) return false;
      if (_filterType != 'ALL' && log.type != _filterType) return false;
      return true;
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Barnard Logs'),
        actions: [
          // サブスクリプション状態
          IconButton(
            icon: Icon(
              logsState.isSubscribed ? Icons.sync : Icons.sync_disabled,
              color: logsState.isSubscribed ? Colors.green : Colors.grey,
            ),
            tooltip: logsState.isSubscribed ? 'Listening' : 'Not listening',
            onPressed: () {
              if (logsState.isSubscribed) {
                ref.read(barnardLogsProvider.notifier).stopListening();
              } else {
                ref.read(barnardLogsProvider.notifier).startListening();
              }
            },
          ),
          // フィルタードロップダウン
          PopupMenuButton<String>(
            icon: const Icon(Icons.filter_list),
            tooltip: 'Filter',
            onSelected: (value) => setState(() => _filterType = value),
            itemBuilder: (context) => _filterOptions
                .map((type) => PopupMenuItem(
                      value: type,
                      child: Row(
                        children: [
                          if (_filterType == type)
                            const Icon(Icons.check, size: 18)
                          else
                            const SizedBox(width: 18),
                          const SizedBox(width: 8),
                          Text(type),
                        ],
                      ),
                    ))
                .toList(),
          ),
          // クリアボタン
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear logs',
            onPressed: () {
              ref.read(barnardLogsProvider.notifier).clearLogs();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // ステータスバー
          _buildStatusBar(bleState, logsState),
          // オプションバー
          _buildOptionsBar(logsState),
          // ログリスト
          Expanded(
            child: filteredLogs.isEmpty
                ? const Center(
                    child: Text('No logs yet.\nStart sensing to see events.'),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    reverse: true,
                    itemCount: filteredLogs.length,
                    itemBuilder: (context, index) {
                      return _buildLogTile(filteredLogs[index]);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBar(BleServiceState bleState, BarnardLogsState logsState) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          Icon(
            bleState.isSensing ? Icons.sensors : Icons.sensors_off,
            size: 16,
            color: bleState.isSensing ? Colors.green : Colors.grey,
          ),
          const SizedBox(width: 8),
          Text(
            bleState.isSensing ? 'Sensing' : 'Stopped',
            style: TextStyle(
              color: bleState.isSensing ? Colors.green : Colors.grey,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 16),
          Text(
            'Mode: ${bleState.eventCode ?? "Anonymous"}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const Spacer(),
          Text(
            '${logsState.logs.length} logs',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _buildOptionsBar(BarnardLogsState logsState) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          FilterChip(
            label: const Text('Show Trace'),
            selected: _showTrace,
            onSelected: (value) => setState(() => _showTrace = value),
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: 8),
          FilterChip(
            label: const Text('Auto-scroll'),
            selected: _autoScroll,
            onSelected: (value) => setState(() => _autoScroll = value),
            visualDensity: VisualDensity.compact,
          ),
          const Spacer(),
          if (_filterType != 'ALL')
            Chip(
              label: Text(_filterType),
              onDeleted: () => setState(() => _filterType = 'ALL'),
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }

  Widget _buildLogTile(BarnardLogEntry log) {
    final color = switch (log.level) {
      LogLevel.trace => Colors.grey,
      LogLevel.info => Colors.blue,
      LogLevel.warn => Colors.orange,
      LogLevel.error => Colors.red,
    };

    final typeColor = switch (log.type) {
      'DETECTION' => Colors.green,
      'RSSI_UPDATE' => Colors.teal,
      'STATE' => Colors.purple,
      'ERROR' => Colors.red,
      'CONSTRAINT' => Colors.orange,
      'DEBUG' => Colors.grey,
      _ => Colors.blue,
    };

    final timeStr =
        '${log.timestamp.hour.toString().padLeft(2, '0')}:${log.timestamp.minute.toString().padLeft(2, '0')}:${log.timestamp.second.toString().padLeft(2, '0')}.${log.timestamp.millisecond.toString().padLeft(3, '0')}';

    return InkWell(
      onTap: log.details != null ? () => _showDetailsDialog(log) : null,
      onLongPress: () {
        Clipboard.setData(
            ClipboardData(text: '[$timeStr] [${log.type}] ${log.message}'));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Copied to clipboard'),
              duration: Duration(seconds: 1)),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: color, width: 3),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // タイムスタンプ
            Text(
              timeStr,
              style: TextStyle(
                fontSize: 10,
                fontFamily: 'monospace',
                color: Colors.grey.shade600,
              ),
            ),
            const SizedBox(width: 8),
            // タイプ
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: typeColor.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                log.type,
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  color: typeColor,
                ),
              ),
            ),
            const SizedBox(width: 8),
            // メッセージ
            Expanded(
              child: Text(
                log.message,
                style: const TextStyle(fontSize: 12),
              ),
            ),
            // 詳細があればアイコン表示
            if (log.details != null)
              Icon(Icons.info_outline, size: 14, color: Colors.grey.shade400),
          ],
        ),
      ),
    );
  }

  void _showDetailsDialog(BarnardLogEntry log) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Text(log.type),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.copy),
              onPressed: () {
                Clipboard.setData(ClipboardData(
                  text: log.details.toString(),
                ));
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Copied')),
                );
              },
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                log.message,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              const Text('Details:',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              ...log.details!.entries.map((e) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${e.key}: ',
                          style: const TextStyle(
                            fontWeight: FontWeight.w500,
                            fontFamily: 'monospace',
                          ),
                        ),
                        Expanded(
                          child: Text(
                            '${e.value}',
                            style: const TextStyle(fontFamily: 'monospace'),
                          ),
                        ),
                      ],
                    ),
                  )),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
