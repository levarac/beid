import 'dart:io';

import 'package:permission_handler/permission_handler.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../core/core.dart';

part 'permission_service.g.dart';

/// パーミッションの状態
enum BlePermissionStatus {
  /// 未確認
  unknown,

  /// 許可済み
  granted,

  /// 拒否された
  denied,

  /// 永久に拒否された（設定から変更が必要）
  permanentlyDenied,

  /// 制限されている（iOS: ペアレンタルコントロール等）
  restricted,
}

/// パーミッションサービスの状態
class PermissionServiceState {
  const PermissionServiceState({
    this.bluetoothStatus = BlePermissionStatus.unknown,
    this.locationStatus = BlePermissionStatus.unknown,
  });

  final BlePermissionStatus bluetoothStatus;
  final BlePermissionStatus locationStatus;

  bool get allGranted =>
      bluetoothStatus == BlePermissionStatus.granted &&
      locationStatus == BlePermissionStatus.granted;

  bool get anyPermanentlyDenied =>
      bluetoothStatus == BlePermissionStatus.permanentlyDenied ||
      locationStatus == BlePermissionStatus.permanentlyDenied;

  PermissionServiceState copyWith({
    BlePermissionStatus? bluetoothStatus,
    BlePermissionStatus? locationStatus,
  }) {
    return PermissionServiceState(
      bluetoothStatus: bluetoothStatus ?? this.bluetoothStatus,
      locationStatus: locationStatus ?? this.locationStatus,
    );
  }
}

/// パーミッションサービスプロバイダー
@riverpod
class PermissionService extends _$PermissionService {
  @override
  PermissionServiceState build() {
    // 初期状態を取得
    _checkPermissions();
    return const PermissionServiceState();
  }

  BlePermissionStatus _mapStatus(PermissionStatus status) {
    return switch (status) {
      PermissionStatus.granted => BlePermissionStatus.granted,
      PermissionStatus.denied => BlePermissionStatus.denied,
      PermissionStatus.permanentlyDenied =>
        BlePermissionStatus.permanentlyDenied,
      PermissionStatus.restricted => BlePermissionStatus.restricted,
      _ => BlePermissionStatus.unknown,
    };
  }

  Future<void> _checkPermissions() async {
    final location = await Permission.locationWhenInUse.status;

    BlePermissionStatus bluetoothStatus;

    if (Platform.isIOS) {
      // iOS: Permission.bluetooth を使用
      final bluetooth = await Permission.bluetooth.status;
      bluetoothStatus = _mapStatus(bluetooth);
    } else {
      // Android 12+: 個別のBluetoothパーミッションを使用
      final bluetoothScan = await Permission.bluetoothScan.status;
      final bluetoothAdvertise = await Permission.bluetoothAdvertise.status;
      final bluetoothConnect = await Permission.bluetoothConnect.status;

      final bluetoothGranted = bluetoothScan.isGranted &&
          bluetoothAdvertise.isGranted &&
          bluetoothConnect.isGranted;

      final bluetoothPermanentlyDenied = bluetoothScan.isPermanentlyDenied ||
          bluetoothAdvertise.isPermanentlyDenied ||
          bluetoothConnect.isPermanentlyDenied;

      bluetoothStatus = bluetoothPermanentlyDenied
          ? BlePermissionStatus.permanentlyDenied
          : bluetoothGranted
              ? BlePermissionStatus.granted
              : BlePermissionStatus.denied;
    }

    state = state.copyWith(
      bluetoothStatus: bluetoothStatus,
      locationStatus: _mapStatus(location),
    );
  }

  /// BLE関連のパーミッションをリクエストする
  Future<Result<void, AppError>> requestBlePermissions() async {
    try {
      BlePermissionStatus bluetoothStatus;

      if (Platform.isIOS) {
        // iOS: Permission.bluetooth を使用
        final bluetoothResult = await Permission.bluetooth.request();
        bluetoothStatus = _mapStatus(bluetoothResult);
      } else {
        // Android 12+: 個別のBluetoothパーミッションをリクエスト
        final bluetoothResults = await [
          Permission.bluetoothScan,
          Permission.bluetoothAdvertise,
          Permission.bluetoothConnect,
        ].request();

        final bluetoothGranted =
            bluetoothResults.values.every((status) => status.isGranted);

        final bluetoothPermanentlyDenied =
            bluetoothResults.values.any((status) => status.isPermanentlyDenied);

        bluetoothStatus = bluetoothPermanentlyDenied
            ? BlePermissionStatus.permanentlyDenied
            : bluetoothGranted
                ? BlePermissionStatus.granted
                : BlePermissionStatus.denied;
      }

      // 位置情報パーミッションをリクエスト（BLEスキャンに必要）
      final locationResult = await Permission.locationWhenInUse.request();

      state = state.copyWith(
        bluetoothStatus: bluetoothStatus,
        locationStatus: _mapStatus(locationResult),
      );

      if (!state.allGranted) {
        if (state.anyPermanentlyDenied) {
          return Failure(BleError(
            message: 'パーミッションが永久に拒否されました。設定から許可してください。',
            type: BleErrorType.permissionDenied,
          ));
        }
        return Failure(BleError(
          message: 'パーミッションが拒否されました',
          type: BleErrorType.permissionDenied,
        ));
      }

      return const Success(null);
    } catch (e, st) {
      return Failure(BleError(
        message: 'パーミッションのリクエストに失敗しました: $e',
        cause: e,
        stackTrace: st,
        type: BleErrorType.unknown,
      ));
    }
  }

  /// 設定画面を開く
  Future<bool> openSettings() async {
    return await openAppSettings();
  }

  /// パーミッションを再確認する
  Future<void> refreshPermissions() async {
    await _checkPermissions();
  }
}
