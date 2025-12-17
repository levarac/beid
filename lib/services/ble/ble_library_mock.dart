import 'dart:async';
import 'dart:math';

import 'ble_library_interface.dart';

/// BLEライブラリのモック実装
///
/// 独自BLEライブラリが完成するまでの開発用モック。
/// 実際のBLE動作をシミュレートする。
class BleLibraryMock implements BleLibraryInterface {
  BleLibraryMock();

  final _stateController = StreamController<BleState>.broadcast();
  final _scanResultController = StreamController<BleDevice>.broadcast();
  final _random = Random();

  BleState _currentState = BleState.poweredOn;
  bool _isScanning = false;
  bool _isAdvertising = false;
  Timer? _mockDeviceTimer;

  // シミュレーション用のモックデバイスUUID
  static const _mockDeviceUuids = [
    'beid-0x1234567890abcdef',
    'beid-0xfedcba0987654321',
    'beid-0xabcdef1234567890',
  ];

  @override
  Stream<BleState> get stateStream => _stateController.stream;

  @override
  Future<BleState> get currentState async => _currentState;

  @override
  Stream<BleDevice> get scanResultStream => _scanResultController.stream;

  @override
  bool get isScanning => _isScanning;

  @override
  bool get isAdvertising => _isAdvertising;

  @override
  Future<void> startScan({List<String>? serviceUuids}) async {
    if (_currentState != BleState.poweredOn) {
      throw StateError('Bluetooth is not powered on');
    }

    if (_isScanning) {
      return;
    }

    _isScanning = true;

    // モックデバイスを定期的に生成
    _mockDeviceTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _emitMockDevice(),
    );

    // 最初のデバイスを即座に生成
    await Future.delayed(const Duration(milliseconds: 500));
    _emitMockDevice();
  }

  void _emitMockDevice() {
    if (!_isScanning) return;

    final uuid = _mockDeviceUuids[_random.nextInt(_mockDeviceUuids.length)];
    final rssi = -40 - _random.nextInt(50); // -40 to -90 dBm

    _scanResultController.add(BleDevice(
      uuid: uuid,
      rssi: rssi,
      timestamp: DateTime.now(),
      name: 'Beid User',
    ));
  }

  @override
  Future<void> stopScan() async {
    _mockDeviceTimer?.cancel();
    _mockDeviceTimer = null;
    _isScanning = false;
  }

  @override
  Future<void> startAdvertising({
    required String serviceUuid,
    String? localName,
  }) async {
    if (_currentState != BleState.poweredOn) {
      throw StateError('Bluetooth is not powered on');
    }

    if (_isAdvertising) {
      return;
    }

    _isAdvertising = true;
    // モックではアドバタイズの実際の動作はシミュレートしない
  }

  @override
  Future<void> stopAdvertising() async {
    _isAdvertising = false;
  }

  /// BLE状態を変更する（テスト用）
  void setBleState(BleState state) {
    _currentState = state;
    _stateController.add(state);

    if (state != BleState.poweredOn) {
      stopScan();
      stopAdvertising();
    }
  }

  @override
  Future<void> dispose() async {
    await stopScan();
    await stopAdvertising();
    await _stateController.close();
    await _scanResultController.close();
  }
}
