import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../core/core.dart';
import 'ble_library_interface.dart';
import 'ble_library_mock.dart';
import 'ble_uuid_generator.dart';

part 'ble_service.g.dart';

/// センシング状態
enum SensingState {
  /// 停止中
  stopped,

  /// 開始中
  starting,

  /// センシング中（スキャン＋アドバタイズ）
  sensing,

  /// 停止処理中
  stopping,
}

/// 検知されたユーザー情報
class DetectedUser {
  const DetectedUser({
    required this.uuid,
    required this.rssi,
    required this.lastSeen,
  });

  final String uuid;
  final int rssi;
  final DateTime lastSeen;

  DetectedUser copyWith({
    String? uuid,
    int? rssi,
    DateTime? lastSeen,
  }) {
    return DetectedUser(
      uuid: uuid ?? this.uuid,
      rssi: rssi ?? this.rssi,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DetectedUser && other.uuid == uuid;
  }

  @override
  int get hashCode => uuid.hashCode;
}

/// BLEサービスの状態
class BleServiceState {
  const BleServiceState({
    this.sensingState = SensingState.stopped,
    this.bleState = BleState.unknown,
    this.detectedUsers = const {},
    this.myUuid,
    this.error,
  });

  final SensingState sensingState;
  final BleState bleState;
  final Set<DetectedUser> detectedUsers;
  final String? myUuid;
  final AppError? error;

  bool get isSensing => sensingState == SensingState.sensing;
  bool get canStartSensing =>
      bleState == BleState.poweredOn && sensingState == SensingState.stopped;

  BleServiceState copyWith({
    SensingState? sensingState,
    BleState? bleState,
    Set<DetectedUser>? detectedUsers,
    String? myUuid,
    AppError? error,
  }) {
    return BleServiceState(
      sensingState: sensingState ?? this.sensingState,
      bleState: bleState ?? this.bleState,
      detectedUsers: detectedUsers ?? this.detectedUsers,
      myUuid: myUuid ?? this.myUuid,
      error: error,
    );
  }
}

/// BLEライブラリプロバイダー
@riverpod
BleLibraryInterface bleLibrary(Ref ref) {
  final library = BleLibraryMock();
  ref.onDispose(() => library.dispose());
  return library;
}

/// BLEサービスプロバイダー
@riverpod
class BleService extends _$BleService {
  BleLibraryInterface? _library;
  StreamSubscription<BleState>? _stateSubscription;
  StreamSubscription<BleDevice>? _scanSubscription;
  Timer? _cleanupTimer;

  static const _userTimeout = Duration(seconds: 10);

  @override
  BleServiceState build() {
    _library = ref.watch(bleLibraryProvider);

    // BLE状態の監視
    _stateSubscription = _library!.stateStream.listen(_onBleStateChanged);

    // 初期状態の取得
    _library!.currentState.then(_onBleStateChanged);

    // 古い検知ユーザーのクリーンアップタイマー
    _cleanupTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _cleanupOldUsers(),
    );

    ref.onDispose(() {
      _stateSubscription?.cancel();
      _scanSubscription?.cancel();
      _cleanupTimer?.cancel();
    });

    return const BleServiceState();
  }

  void _onBleStateChanged(BleState bleState) {
    state = state.copyWith(bleState: bleState);

    // BLEがオフになったらセンシングを停止
    if (bleState != BleState.poweredOn && state.isSensing) {
      stopSensing();
    }
  }

  void _onDeviceDetected(BleDevice device) {
    // Beid UUIDのみを処理
    if (!BleUuidGenerator.isBeidUuid(device.uuid)) {
      return;
    }

    // 自分自身は除外
    if (device.uuid == state.myUuid) {
      return;
    }

    final detectedUser = DetectedUser(
      uuid: device.uuid,
      rssi: device.rssi,
      lastSeen: device.timestamp,
    );

    final updatedUsers = Set<DetectedUser>.from(state.detectedUsers);

    // 既存のユーザーを更新または新規追加
    updatedUsers.removeWhere((u) => u.uuid == device.uuid);
    updatedUsers.add(detectedUser);

    state = state.copyWith(detectedUsers: updatedUsers);
  }

  void _cleanupOldUsers() {
    final now = DateTime.now();
    final updatedUsers = state.detectedUsers
        .where((u) => now.difference(u.lastSeen) < _userTimeout)
        .toSet();

    if (updatedUsers.length != state.detectedUsers.length) {
      state = state.copyWith(detectedUsers: updatedUsers);
    }
  }

  /// センシングを開始する
  ///
  /// [walletAddress] 自分のウォレットアドレス
  Future<Result<void, AppError>> startSensing(String walletAddress) async {
    if (state.bleState != BleState.poweredOn) {
      return Failure(BleError(
        message: 'Bluetoothが有効ではありません',
        type: BleErrorType.bluetoothDisabled,
      ));
    }

    if (state.sensingState != SensingState.stopped) {
      return const Success(null);
    }

    state = state.copyWith(sensingState: SensingState.starting);

    try {
      // ウォレットアドレスからUUIDを生成
      final myUuid = BleUuidGenerator.generateFromWalletAddress(walletAddress);
      state = state.copyWith(myUuid: myUuid);

      // スキャン結果の購読
      _scanSubscription = _library!.scanResultStream.listen(_onDeviceDetected);

      // アドバタイズを開始
      await _library!.startAdvertising(
        serviceUuid: myUuid,
        localName: 'Beid',
      );

      // スキャンを開始
      await _library!.startScan();

      state = state.copyWith(
        sensingState: SensingState.sensing,
        detectedUsers: {},
      );

      return const Success(null);
    } catch (e, st) {
      state = state.copyWith(sensingState: SensingState.stopped);
      return Failure(BleError(
        message: 'センシングの開始に失敗しました: $e',
        cause: e,
        stackTrace: st,
        type: BleErrorType.unknown,
      ));
    }
  }

  /// センシングを停止する
  Future<Result<void, AppError>> stopSensing() async {
    if (state.sensingState == SensingState.stopped) {
      return const Success(null);
    }

    state = state.copyWith(sensingState: SensingState.stopping);

    try {
      await _scanSubscription?.cancel();
      _scanSubscription = null;

      await _library!.stopScan();
      await _library!.stopAdvertising();

      state = state.copyWith(
        sensingState: SensingState.stopped,
        detectedUsers: {},
      );

      return const Success(null);
    } catch (e, st) {
      state = state.copyWith(sensingState: SensingState.stopped);
      return Failure(BleError(
        message: 'センシングの停止に失敗しました: $e',
        cause: e,
        stackTrace: st,
        type: BleErrorType.unknown,
      ));
    }
  }

  /// センシングをトグルする
  Future<Result<void, AppError>> toggleSensing(String walletAddress) async {
    if (state.isSensing) {
      return stopSensing();
    } else {
      return startSensing(walletAddress);
    }
  }
}
