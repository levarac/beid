import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:barnard/barnard.dart';
import 'package:barnard/barnard_ble.dart';
import 'package:barnard/mock_barnard.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../core/core.dart';

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
    required this.displayId,
    required this.rssi,
    required this.lastSeen,
    this.rssiSummary,
    this.smoothedRssi,
    this.resolvedDisplayId,
    this.resolvedTek,
  });

  /// 表示用ID（rpidから生成された短いID）
  final String displayId;

  /// 受信信号強度（dBm）- 生の値
  final int rssi;

  /// スムージングされたRSSI値（表示用）
  final double? smoothedRssi;

  /// 最終検知時刻
  final DateTime lastSeen;

  /// RSSI統計情報
  final RssiSummary? rssiSummary;

  /// イベントモード時の解決済み表示ID（TEKの先頭3バイトのhex）
  final String? resolvedDisplayId;

  /// 解決済みTEK（イベントモード時のみ）
  final Uint8List? resolvedTek;

  /// 表示用のRSSI（スムージング済みがあればそれを使用）
  int get displayRssi => smoothedRssi?.round() ?? rssi;

  /// イベントモード時はresolvedDisplayIdを優先する表示ID
  String get effectiveDisplayId => resolvedDisplayId ?? displayId;

  DetectedUser copyWith({
    String? displayId,
    int? rssi,
    DateTime? lastSeen,
    RssiSummary? rssiSummary,
    double? smoothedRssi,
    String? resolvedDisplayId,
    Uint8List? resolvedTek,
  }) {
    return DetectedUser(
      displayId: displayId ?? this.displayId,
      rssi: rssi ?? this.rssi,
      lastSeen: lastSeen ?? this.lastSeen,
      rssiSummary: rssiSummary ?? this.rssiSummary,
      smoothedRssi: smoothedRssi ?? this.smoothedRssi,
      resolvedDisplayId: resolvedDisplayId ?? this.resolvedDisplayId,
      resolvedTek: resolvedTek ?? this.resolvedTek,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DetectedUser && other.displayId == displayId;
  }

  @override
  int get hashCode => displayId.hashCode;
}

/// BLE状態（アプリ内で使用）
enum BleState {
  unknown,
  poweredOff,
  poweredOn,
  unsupported,
  unauthorized,
}

/// BLEサービスの状態
class BleServiceState {
  const BleServiceState({
    this.sensingState = SensingState.stopped,
    this.bleState = BleState.poweredOn, // MockではpoweredOnとして扱う
    this.detectedUsers = const {},
    this.isScanning = false,
    this.isAdvertising = false,
    this.eventCode,
    this.error,
  });

  final SensingState sensingState;
  final BleState bleState;
  final Set<DetectedUser> detectedUsers;
  final bool isScanning;
  final bool isAdvertising;
  final String? eventCode;
  final AppError? error;

  bool get isSensing => sensingState == SensingState.sensing;
  bool get isEventMode => eventCode != null;
  bool get canStartSensing =>
      bleState == BleState.poweredOn && sensingState == SensingState.stopped;

  BleServiceState copyWith({
    SensingState? sensingState,
    BleState? bleState,
    Set<DetectedUser>? detectedUsers,
    bool? isScanning,
    bool? isAdvertising,
    String? eventCode,
    bool clearEventCode = false,
    AppError? error,
  }) {
    return BleServiceState(
      sensingState: sensingState ?? this.sensingState,
      bleState: bleState ?? this.bleState,
      detectedUsers: detectedUsers ?? this.detectedUsers,
      isScanning: isScanning ?? this.isScanning,
      isAdvertising: isAdvertising ?? this.isAdvertising,
      eventCode: clearEventCode ? null : (eventCode ?? this.eventCode),
      error: error,
    );
  }
}

/// BLEサービスプロバイダー
@riverpod
class BleService extends _$BleService {
  BarnardClient? _client;
  StreamSubscription<BarnardEvent>? _eventSubscription;
  Timer? _cleanupTimer;

  /// BarnardClientを公開（デバッグ用）
  BarnardClient? get client => _client;

  // 高頻度RSSI更新があるため、タイムアウトは短めで良い
  static const _userTimeout = Duration(seconds: 15);

  /// EMAスムージング係数（0.0-1.0、小さいほど滑らか）
  static const _smoothingAlpha = 0.2;

  @override
  BleServiceState build() {
    ref.onDispose(() {
      _eventSubscription?.cancel();
      _cleanupTimer?.cancel();
      _client?.dispose();
    });

    // BLEクライアントを非同期で初期化開始
    _initializeClient();

    return const BleServiceState();
  }

  Future<void> _initializeClient() async {
    try {
      // iOS/Androidでは実際のBLEクライアントを使用、その他はモック
      if (Platform.isIOS || Platform.isAndroid) {
        _client = await BarnardBleClient.create();
      } else {
        _client = MockBarnard(
          simulatedPeerCount: 10,
          tickMs: 500,
        );
      }

      // barnard側のイベントモード状態を同期
      if (_client!.currentMode == EventMode.event && _client!.currentEventCode != null) {
        state = state.copyWith(eventCode: _client!.currentEventCode);
      }

      // イベントの監視
      _eventSubscription = _client!.events.listen(_onBarnardEvent);

      // 古い検知ユーザーのクリーンアップタイマー
      _cleanupTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => _cleanupOldUsers(),
      );
    } catch (e) {
      state = state.copyWith(
        bleState: BleState.unsupported,
        error: BleError(
          message: 'BLEクライアントの初期化に失敗: $e',
          type: BleErrorType.unknown,
        ),
      );
    }
  }

  void _onBarnardEvent(BarnardEvent event) {
    switch (event) {
      case DetectionEvent():
        _onDetection(event);
      case RssiUpdateEvent():
        _onRssiUpdate(event);
      case StateEvent():
        _onStateChange(event);
      case ConstraintEvent():
        _onConstraint(event);
      case ErrorEvent():
        _onError(event);
    }
  }

  void _onDetection(DetectionEvent event) {
    final existingUser = state.detectedUsers.cast<DetectedUser?>().firstWhere(
          (u) => u?.displayId == event.displayId,
          orElse: () => null,
        );

    // EMAスムージングを適用
    final newSmoothedRssi = _calculateSmoothedRssi(
      existingUser?.smoothedRssi,
      event.rssi.toDouble(),
    );

    final detectedUser = DetectedUser(
      displayId: event.displayId,
      rssi: event.rssi,
      lastSeen: event.timestamp,
      rssiSummary: event.rssiSummary,
      smoothedRssi: newSmoothedRssi,
      resolvedDisplayId: event.resolvedDisplayId,
      resolvedTek: event.resolvedTek,
    );

    final updatedUsers = Set<DetectedUser>.from(state.detectedUsers);

    // 既存のユーザーを更新または新規追加
    updatedUsers.removeWhere((u) => u.displayId == event.displayId);
    updatedUsers.add(detectedUser);

    state = state.copyWith(detectedUsers: updatedUsers);
  }

  /// 高頻度RSSI更新イベントを処理
  void _onRssiUpdate(RssiUpdateEvent event) {
    final existingUser = state.detectedUsers.cast<DetectedUser?>().firstWhere(
          (u) => u?.displayId == event.displayId,
          orElse: () => null,
        );

    if (existingUser == null) {
      // 未知のピアからのRSSI更新は無視（DetectionEventで初回登録される）
      return;
    }

    // EMAスムージングを適用
    final newSmoothedRssi = _calculateSmoothedRssi(
      existingUser.smoothedRssi,
      event.rssi.toDouble(),
    );

    final updatedUser = existingUser.copyWith(
      rssi: event.rssi,
      lastSeen: event.timestamp,
      smoothedRssi: newSmoothedRssi,
      resolvedDisplayId: event.resolvedDisplayId ?? existingUser.resolvedDisplayId,
    );

    final updatedUsers = Set<DetectedUser>.from(state.detectedUsers);
    updatedUsers.removeWhere((u) => u.displayId == event.displayId);
    updatedUsers.add(updatedUser);

    state = state.copyWith(detectedUsers: updatedUsers);
  }

  /// EMAスムージングを計算
  double _calculateSmoothedRssi(double? previousSmoothed, double newRssi) {
    if (previousSmoothed == null) {
      return newRssi;
    }
    return _smoothingAlpha * newRssi + (1 - _smoothingAlpha) * previousSmoothed;
  }

  void _onStateChange(StateEvent event) {
    state = state.copyWith(
      isScanning: event.state.isScanning,
      isAdvertising: event.state.isAdvertising,
    );

    // 両方停止したらセンシング停止状態に
    if (!event.state.isScanning && !event.state.isAdvertising) {
      if (state.sensingState == SensingState.sensing) {
        state = state.copyWith(sensingState: SensingState.stopped);
      }
    }
  }

  void _onConstraint(ConstraintEvent event) {
    // 制約イベント（パーミッション不足など）
    state = state.copyWith(
      error: BleError(
        message: event.message ?? event.code,
        type: BleErrorType.permissionDenied,
      ),
    );
  }

  void _onError(ErrorEvent event) {
    state = state.copyWith(
      error: BleError(
        message: event.message,
        type: BleErrorType.unknown,
      ),
    );
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

  /// イベントに参加する
  Future<Result<void, AppError>> joinEvent(String eventCode) async {
    if (_client == null) {
      return Failure(BleError(
        message: 'BLEクライアントが初期化されていません',
        type: BleErrorType.unknown,
      ));
    }

    try {
      await _client!.joinEvent(eventCode);
      state = state.copyWith(eventCode: eventCode);
      return const Success(null);
    } catch (e, st) {
      return Failure(BleError(
        message: 'イベント参加に失敗しました: $e',
        cause: e,
        stackTrace: st,
        type: BleErrorType.unknown,
      ));
    }
  }

  /// イベントから離脱する
  Future<Result<void, AppError>> leaveEvent() async {
    if (_client == null) {
      return Failure(BleError(
        message: 'BLEクライアントが初期化されていません',
        type: BleErrorType.unknown,
      ));
    }

    try {
      await _client!.leaveEvent();
      state = state.copyWith(clearEventCode: true);
      return const Success(null);
    } catch (e, st) {
      return Failure(BleError(
        message: 'イベント離脱に失敗しました: $e',
        cause: e,
        stackTrace: st,
        type: BleErrorType.unknown,
      ));
    }
  }

  /// センシングを開始する
  Future<Result<void, AppError>> startSensing() async {
    if (_client == null) {
      return Failure(BleError(
        message: 'BLEクライアントが初期化されていません',
        type: BleErrorType.unknown,
      ));
    }

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
      // スキャン+アドバタイズを同時に開始
      final result = await _client!.startAuto();

      if (!result.scanningStarted && !result.advertisingStarted) {
        state = state.copyWith(sensingState: SensingState.stopped);
        final issues = result.issues.map((i) => i.message ?? i.code).join(', ');
        return Failure(BleError(
          message: 'センシングの開始に失敗しました: $issues',
          type: BleErrorType.unknown,
        ));
      }

      state = state.copyWith(
        sensingState: SensingState.sensing,
        detectedUsers: {},
        isScanning: result.scanningStarted,
        isAdvertising: result.advertisingStarted,
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
      await _client!.stopAuto();

      state = state.copyWith(
        sensingState: SensingState.stopped,
        detectedUsers: {},
        isScanning: false,
        isAdvertising: false,
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
  Future<Result<void, AppError>> toggleSensing() async {
    if (state.isSensing) {
      return stopSensing();
    } else {
      return startSensing();
    }
  }

  /// RSSIサンプルを取得する
  List<RssiSample> getRssiSamples({DateTime? since, int? limit}) {
    return _client?.getRssiSamples(since: since, limit: limit) ?? [];
  }

  /// 特定のユーザーのRSSI履歴を取得（rpidのbase64エンコード文字列で指定）
  List<RssiSample> getRssiSamplesForUser(String displayId, {int? limit}) {
    // displayIdからrpidを復元することはできないため、
    // 全サンプルから該当するものをフィルタリング
    final samples = _client?.getRssiSamples(limit: limit ?? 100) ?? [];
    return samples.where((s) {
      final sDisplayId = _displayIdFromRpid(s.rpid);
      return sDisplayId == displayId;
    }).toList();
  }

  String _displayIdFromRpid(List<int> rpid) {
    final take = rpid.length < 4 ? rpid.length : 4;
    return rpid.sublist(0, take).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
