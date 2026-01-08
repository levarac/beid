import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:uuid/uuid.dart';

part 'device_id_service.g.dart';

/// デバイスID管理サービスの状態
class DeviceIdState {
  const DeviceIdState({
    this.deviceId,
    this.isInitialized = false,
  });

  /// デバイスのユニークID（UUID v4）
  final String? deviceId;

  /// 初期化済みかどうか
  final bool isInitialized;

  /// 短い表示用ID（最初の8文字）
  String? get shortId {
    if (deviceId == null) return null;
    return deviceId!.substring(0, 8);
  }

  DeviceIdState copyWith({
    String? deviceId,
    bool? isInitialized,
  }) {
    return DeviceIdState(
      deviceId: deviceId ?? this.deviceId,
      isInitialized: isInitialized ?? this.isInitialized,
    );
  }
}

/// デバイスID管理サービス
///
/// アプリインストール時にUUIDを自動生成し、セキュアストレージに永続化する
@Riverpod(keepAlive: true)
class DeviceIdService extends _$DeviceIdService {
  static const _storageKey = 'beid_device_id';
  final _storage = const FlutterSecureStorage();
  final _uuid = const Uuid();

  @override
  DeviceIdState build() {
    return const DeviceIdState();
  }

  /// デバイスIDを初期化（既存があれば読み込み、なければ新規生成）
  Future<void> initialize() async {
    if (state.isInitialized) return;

    // 既存のデバイスIDを読み込み
    String? existingId = await _storage.read(key: _storageKey);

    if (existingId == null) {
      // 新規生成
      existingId = _uuid.v4();
      await _storage.write(key: _storageKey, value: existingId);
    }

    state = state.copyWith(
      deviceId: existingId,
      isInitialized: true,
    );
  }

  /// デバイスIDをリセット（新しいUUIDを生成）
  Future<void> resetDeviceId() async {
    final newId = _uuid.v4();
    await _storage.write(key: _storageKey, value: newId);

    state = state.copyWith(deviceId: newId);
  }
}
