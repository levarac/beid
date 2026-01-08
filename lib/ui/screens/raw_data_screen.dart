import 'dart:async';
import 'dart:io';

import 'package:barnard/barnard.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../services/ble/ble_service.dart';

/// BLEローデータ表示画面
class RawDataScreen extends ConsumerStatefulWidget {
  const RawDataScreen({super.key});

  @override
  ConsumerState<RawDataScreen> createState() => _RawDataScreenState();
}

class _RawDataScreenState extends ConsumerState<RawDataScreen> {
  List<RssiSample> _samples = [];
  Timer? _refreshTimer;
  bool _autoRefresh = true;
  int _sampleCount = 100;

  // 統計情報
  int _samplesPerSecond = 0;
  DateTime? _lastCountTime;
  int _lastCount = 0;

  // 録画機能
  bool _isRecording = false;
  List<RssiSample> _recordedSamples = [];
  DateTime? _recordingStartTime;

  @override
  void initState() {
    super.initState();
    _startAutoRefresh();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  void _startAutoRefresh() {
    _refreshTimer?.cancel();
    if (_autoRefresh) {
      _refreshTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        _refreshData();
      });
    }
  }

  void _refreshData() {
    final bleService = ref.read(bleServiceProvider.notifier);
    final samples = bleService.getRssiSamples(limit: _sampleCount);

    // サンプル/秒を計算
    final now = DateTime.now();
    if (_lastCountTime != null) {
      final elapsed = now.difference(_lastCountTime!).inMilliseconds;
      if (elapsed >= 1000) {
        final newSamples = samples.length - _lastCount;
        _samplesPerSecond = (newSamples * 1000 / elapsed).round();
        _lastCountTime = now;
        _lastCount = samples.length;
      }
    } else {
      _lastCountTime = now;
      _lastCount = samples.length;
    }

    // 録画中はサンプルを蓄積
    _recordSamples();

    setState(() {
      _samples = samples;
    });
  }

  String _formatTimestamp(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')}.'
        '${time.millisecond.toString().padLeft(3, '0')}';
  }

  String _formatRpid(List<int> rpid) {
    return rpid.take(4).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  String _formatRpidFull(List<int> rpid) {
    return rpid.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  void _copyToClipboard() {
    final buffer = StringBuffer();
    buffer.writeln('timestamp,rpid_short,rpid_full,rssi,transport');
    for (final sample in _samples) {
      buffer.writeln(
        '${sample.timestamp.toIso8601String()},'
        '${_formatRpid(sample.rpid)},'
        '${_formatRpidFull(sample.rpid)},'
        '${sample.rssi},'
        '${sample.transport.name}',
      );
    }
    Clipboard.setData(ClipboardData(text: buffer.toString()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('CSVをクリップボードにコピーしました')),
    );
  }

  void _toggleRecording() {
    setState(() {
      if (_isRecording) {
        // 録画停止 → ファイル保存ダイアログ
        _isRecording = false;
        if (_recordedSamples.isNotEmpty) {
          _showSaveDialog();
        }
      } else {
        // 録画開始
        _isRecording = true;
        _recordedSamples = [];
        _recordingStartTime = DateTime.now();
      }
    });
  }

  void _recordSamples() {
    if (!_isRecording) return;

    final bleService = ref.read(bleServiceProvider.notifier);
    final newSamples = bleService.getRssiSamples(
      since: _recordedSamples.isEmpty
          ? _recordingStartTime
          : _recordedSamples.last.timestamp,
    );

    // 重複を避けて追加
    for (final sample in newSamples) {
      if (_recordedSamples.isEmpty ||
          sample.timestamp.isAfter(_recordedSamples.last.timestamp)) {
        _recordedSamples.add(sample);
      }
    }
  }

  void _showSaveDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('録画データを保存'),
        content: Text('${_recordedSamples.length}件のサンプルを保存しますか？'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _recordedSamples = [];
            },
            child: const Text('破棄'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _saveToFile();
            },
            child: const Text('保存'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _shareFile();
            },
            child: const Text('共有'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveToFile() async {
    try {
      final file = await _createCsvFile();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存しました: ${file.path}')),
      );
      _recordedSamples = [];
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存エラー: $e')),
      );
    }
  }

  Future<void> _shareFile() async {
    try {
      final file = await _createCsvFile();
      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'RSSI Raw Data',
      );
      _recordedSamples = [];
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('共有エラー: $e')),
      );
    }
  }

  Future<File> _createCsvFile() async {
    final directory = await getApplicationDocumentsDirectory();
    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
    final file = File('${directory.path}/rssi_data_$timestamp.csv');

    final buffer = StringBuffer();
    buffer.writeln('timestamp,rpid_short,rpid_full,rssi,transport');
    for (final sample in _recordedSamples) {
      buffer.writeln(
        '${sample.timestamp.toIso8601String()},'
        '${_formatRpid(sample.rpid)},'
        '${_formatRpidFull(sample.rpid)},'
        '${sample.rssi},'
        '${sample.transport.name}',
      );
    }

    await file.writeAsString(buffer.toString());
    return file;
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final bleState = ref.watch(bleServiceProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('RSSIローデータ'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            onPressed: _samples.isNotEmpty ? _copyToClipboard : null,
            tooltip: 'CSVコピー',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refreshData,
            tooltip: '更新',
          ),
        ],
      ),
      body: Column(
        children: [
          // 統計情報カード
          Card(
            margin: const EdgeInsets.all(16),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'サンプル数: ${_samples.length}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        '$_samplesPerSecond samples/sec',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.green,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Text('自動更新'),
                      Switch(
                        value: _autoRefresh,
                        onChanged: (value) {
                          setState(() {
                            _autoRefresh = value;
                          });
                          _startAutoRefresh();
                        },
                      ),
                      const SizedBox(width: 16),
                      const Text('表示件数:'),
                      const SizedBox(width: 8),
                      DropdownButton<int>(
                        value: _sampleCount,
                        items: const [
                          DropdownMenuItem(value: 50, child: Text('50')),
                          DropdownMenuItem(value: 100, child: Text('100')),
                          DropdownMenuItem(value: 200, child: Text('200')),
                          DropdownMenuItem(value: 500, child: Text('500')),
                        ],
                        onChanged: (value) {
                          setState(() {
                            _sampleCount = value ?? 100;
                          });
                          _refreshData();
                        },
                      ),
                    ],
                  ),
                  if (!bleState.isSensing)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'センシング停止中 - データは更新されません',
                        style: TextStyle(color: Colors.orange.shade700),
                      ),
                    ),
                  const Divider(),
                  // 録画機能
                  Row(
                    children: [
                      ElevatedButton.icon(
                        onPressed: _toggleRecording,
                        icon: Icon(_isRecording ? Icons.stop : Icons.fiber_manual_record),
                        label: Text(_isRecording ? '録画停止' : '録画開始'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _isRecording ? Colors.red : null,
                          foregroundColor: _isRecording ? Colors.white : null,
                        ),
                      ),
                      const SizedBox(width: 16),
                      if (_isRecording) ...[
                        Icon(Icons.fiber_manual_record, color: Colors.red, size: 12),
                        const SizedBox(width: 4),
                        Text(
                          '録画中: ${_recordedSamples.length}件',
                          style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _formatDuration(DateTime.now().difference(_recordingStartTime!)),
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),

          // ヘッダー
          Container(
            color: Colors.grey.shade200,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: const Row(
              children: [
                SizedBox(width: 100, child: Text('時刻', style: TextStyle(fontWeight: FontWeight.bold))),
                SizedBox(width: 80, child: Text('RPID', style: TextStyle(fontWeight: FontWeight.bold))),
                SizedBox(width: 60, child: Text('RSSI', style: TextStyle(fontWeight: FontWeight.bold))),
                Expanded(child: Text('強度', style: TextStyle(fontWeight: FontWeight.bold))),
              ],
            ),
          ),

          // データリスト
          Expanded(
            child: _samples.isEmpty
                ? const Center(child: Text('データがありません'))
                : ListView.builder(
                    itemCount: _samples.length,
                    itemBuilder: (context, index) {
                      final sample = _samples[index];
                      final rssiNormalized = ((sample.rssi + 100) / 70).clamp(0.0, 1.0);

                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(color: Colors.grey.shade300),
                          ),
                        ),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 100,
                              child: Text(
                                _formatTimestamp(sample.timestamp),
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 80,
                              child: Text(
                                _formatRpid(sample.rpid),
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 60,
                              child: Text(
                                '${sample.rssi}',
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                  color: _getRssiColor(sample.rssi),
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            Expanded(
                              child: LinearProgressIndicator(
                                value: rssiNormalized,
                                backgroundColor: Colors.grey.shade200,
                                valueColor: AlwaysStoppedAnimation(
                                  _getRssiColor(sample.rssi),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Color _getRssiColor(int rssi) {
    if (rssi >= -50) return Colors.green;
    if (rssi >= -70) return Colors.orange;
    return Colors.red;
  }
}
