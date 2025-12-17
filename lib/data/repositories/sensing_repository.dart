import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:uuid/uuid.dart';

import '../../core/core.dart';
import '../models/sensing_record.dart';

part 'sensing_repository.g.dart';

/// センシングリポジトリプロバイダー
@Riverpod(keepAlive: true)
class SensingRepository extends _$SensingRepository {
  Box<SensingRecord>? _box;
  final _uuid = const Uuid();
  final _historyController = StreamController<List<SensingRecord>>.broadcast();

  static const _boxName = 'sensing_records';

  @override
  Future<void> build() async {
    await _initBox();

    ref.onDispose(() {
      _historyController.close();
    });
  }

  Future<void> _initBox() async {
    if (!Hive.isBoxOpen(_boxName)) {
      _box = await Hive.openBox<SensingRecord>(_boxName);
    } else {
      _box = Hive.box<SensingRecord>(_boxName);
    }
  }

  /// 履歴のストリーム
  Stream<List<SensingRecord>> get historyStream => _historyController.stream;

  /// 全ての履歴を取得
  List<SensingRecord> getAll() {
    _ensureBoxOpen();
    final records = _box!.values.toList();
    // 新しい順にソート
    records.sort((a, b) => b.detectedAt.compareTo(a.detectedAt));
    return records;
  }

  /// IDで記録を取得
  SensingRecord? getById(String id) {
    _ensureBoxOpen();
    return _box!.values.where((r) => r.id == id).firstOrNull;
  }

  /// パートナーUUIDで最新の記録を取得
  SensingRecord? getLatestByPartnerUuid(String partnerUuid) {
    _ensureBoxOpen();
    final records =
        _box!.values.where((r) => r.partnerUuid == partnerUuid).toList();
    if (records.isEmpty) return null;
    records.sort((a, b) => b.detectedAt.compareTo(a.detectedAt));
    return records.first;
  }

  /// 検知情報を保存
  Future<Result<SensingRecord, AppError>> saveDetection({
    required String partnerUuid,
    required int rssi,
  }) async {
    try {
      _ensureBoxOpen();

      final record = SensingRecord(
        id: _uuid.v4(),
        partnerUuid: partnerUuid,
        rssi: rssi,
        detectedAt: DateTime.now(),
      );

      await _box!.add(record);
      _notifyHistoryUpdate();

      return Success(record);
    } catch (e, st) {
      return Failure(StorageError(
        message: '検知情報の保存に失敗しました: $e',
        cause: e,
        stackTrace: st,
        type: StorageErrorType.writeFailed,
      ));
    }
  }

  /// 記録のステータスを更新
  Future<Result<void, AppError>> updateStatus({
    required String id,
    required SensingStatus status,
    String? txHash,
    String? errorMessage,
  }) async {
    try {
      _ensureBoxOpen();

      final record = getById(id);
      if (record == null) {
        return Failure(StorageError(
          message: '記録が見つかりません: $id',
          type: StorageErrorType.readFailed,
        ));
      }

      record.updateStatus(status, txHash: txHash, error: errorMessage);
      _notifyHistoryUpdate();

      return const Success(null);
    } catch (e, st) {
      return Failure(StorageError(
        message: 'ステータスの更新に失敗しました: $e',
        cause: e,
        stackTrace: st,
        type: StorageErrorType.writeFailed,
      ));
    }
  }

  /// 古い記録を削除
  Future<Result<int, AppError>> cleanupOldRecords(Duration maxAge) async {
    try {
      _ensureBoxOpen();

      final cutoffDate = DateTime.now().subtract(maxAge);
      final keysToDelete = <dynamic>[];

      for (final entry in _box!.toMap().entries) {
        if (entry.value.detectedAt.isBefore(cutoffDate)) {
          keysToDelete.add(entry.key);
        }
      }

      await _box!.deleteAll(keysToDelete);
      _notifyHistoryUpdate();

      return Success(keysToDelete.length);
    } catch (e, st) {
      return Failure(StorageError(
        message: '古い記録の削除に失敗しました: $e',
        cause: e,
        stackTrace: st,
        type: StorageErrorType.deleteFailed,
      ));
    }
  }

  /// 全ての記録を削除
  Future<Result<void, AppError>> clearAll() async {
    try {
      _ensureBoxOpen();
      await _box!.clear();
      _notifyHistoryUpdate();
      return const Success(null);
    } catch (e, st) {
      return Failure(StorageError(
        message: '記録のクリアに失敗しました: $e',
        cause: e,
        stackTrace: st,
        type: StorageErrorType.deleteFailed,
      ));
    }
  }

  void _ensureBoxOpen() {
    if (_box == null || !_box!.isOpen) {
      throw StateError('Hive box is not initialized');
    }
  }

  void _notifyHistoryUpdate() {
    _historyController.add(getAll());
  }
}

/// 履歴リストプロバイダー
@riverpod
Stream<List<SensingRecord>> sensingHistory(Ref ref) async* {
  // リポジトリが初期化されるまで待機
  await ref.watch(sensingRepositoryProvider.future);
  final repository = ref.watch(sensingRepositoryProvider.notifier);

  // 初期データを取得
  yield repository.getAll();

  // ストリームを購読
  yield* repository.historyStream;
}
