import 'package:hive_ce/hive.dart';

part 'sensing_record.g.dart';

/// センシング記録のステータス
@HiveType(typeId: 0)
enum SensingStatus {
  /// 検知済み（未報告）
  @HiveField(0)
  detected,

  /// 報告済み（検証待ち）
  @HiveField(1)
  pending,

  /// 検証済み（相互センシング成立）
  @HiveField(2)
  verified,

  /// POAP発行済み
  @HiveField(3)
  poapIssued,

  /// 失敗
  @HiveField(4)
  failed,
}

/// センシング記録
@HiveType(typeId: 1)
class SensingRecord extends HiveObject {
  SensingRecord({
    required this.id,
    required this.partnerUuid,
    required this.rssi,
    required this.detectedAt,
    this.status = SensingStatus.detected,
    this.txHash,
    this.errorMessage,
  });

  /// 記録のユニークID
  @HiveField(0)
  final String id;

  /// パートナーのUUID（BLEで検知したUUID）
  @HiveField(1)
  final String partnerUuid;

  /// 受信信号強度（dBm）
  @HiveField(2)
  final int rssi;

  /// 検知日時
  @HiveField(3)
  final DateTime detectedAt;

  /// ステータス
  @HiveField(4)
  SensingStatus status;

  /// POAPトランザクションハッシュ（発行済みの場合）
  @HiveField(5)
  String? txHash;

  /// エラーメッセージ（失敗時）
  @HiveField(6)
  String? errorMessage;

  /// ステータスを更新
  void updateStatus(SensingStatus newStatus, {String? txHash, String? error}) {
    status = newStatus;
    if (txHash != null) this.txHash = txHash;
    if (error != null) errorMessage = error;
    save();
  }

  @override
  String toString() =>
      'SensingRecord(id: $id, partner: $partnerUuid, status: $status)';
}
