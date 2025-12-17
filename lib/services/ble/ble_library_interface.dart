// 独自BLEライブラリとのインターフェース定義
//
// このインターフェースは別リポジトリで開発中のBLEライブラリと合意された仕様に基づく。
// 実際のライブラリが完成するまでは、モック実装を使用して開発を進める。

/// BLEデバイス情報
class BleDevice {
  const BleDevice({
    required this.uuid,
    required this.rssi,
    required this.timestamp,
    this.name,
  });

  /// デバイスのユニークID（アドバタイズされているサービスUUID）
  final String uuid;

  /// 受信信号強度（dBm）
  final int rssi;

  /// 検知タイムスタンプ
  final DateTime timestamp;

  /// デバイス名（オプション）
  final String? name;

  @override
  String toString() => 'BleDevice(uuid: $uuid, rssi: $rssi)';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is BleDevice && other.uuid == uuid;
  }

  @override
  int get hashCode => uuid.hashCode;
}

/// BLE状態
enum BleState {
  /// 不明
  unknown,

  /// 電源オフ
  poweredOff,

  /// 電源オン（利用可能）
  poweredOn,

  /// サポートされていない
  unsupported,

  /// 権限なし
  unauthorized,
}

/// BLEライブラリインターフェース
///
/// Central（スキャン）とPeripheral（アドバタイズ）両方の機能を提供する。
abstract interface class BleLibraryInterface {
  /// BLE状態のストリーム
  Stream<BleState> get stateStream;

  /// 現在のBLE状態
  Future<BleState> get currentState;

  /// スキャン結果のストリーム
  Stream<BleDevice> get scanResultStream;

  /// スキャンを開始する
  ///
  /// [serviceUuids] フィルタリングするサービスUUIDのリスト
  /// スキャン中に検知されたデバイスは[scanResultStream]に流れる
  Future<void> startScan({List<String>? serviceUuids});

  /// スキャンを停止する
  Future<void> stopScan();

  /// スキャン中かどうか
  bool get isScanning;

  /// アドバタイズを開始する
  ///
  /// [serviceUuid] アドバタイズするサービスUUID
  /// [localName] アドバタイズするローカル名（オプション）
  Future<void> startAdvertising({
    required String serviceUuid,
    String? localName,
  });

  /// アドバタイズを停止する
  Future<void> stopAdvertising();

  /// アドバタイズ中かどうか
  bool get isAdvertising;

  /// リソースを解放する
  Future<void> dispose();
}
