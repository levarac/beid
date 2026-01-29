import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../providers/app_providers.dart';
import '../ble/ble_service.dart';

part 'position_service.g.dart';

/// WebSocket接続状態
enum PositionConnectionState {
  disconnected,
  connecting,
  connected,
  reconnecting,
}

/// ユーザーの位置情報
class UserPosition {
  final String targetUserId;
  final double angle; // radians
  final double distance; // 0-1
  final int rssi;

  const UserPosition({
    required this.targetUserId,
    required this.angle,
    required this.distance,
    required this.rssi,
  });

  factory UserPosition.fromJson(Map<String, dynamic> json) {
    return UserPosition(
      targetUserId: json['targetUserId'] as String,
      angle: (json['angle'] as num).toDouble() * 3.14159265359 / 180, // Convert degrees to radians
      distance: (json['distance'] as num).toDouble(),
      rssi: (json['rssi'] as num).toInt(),
    );
  }
}

/// 位置更新イベント
class PositionUpdate {
  final String userId;
  final List<UserPosition> positions;
  final DateTime timestamp;

  const PositionUpdate({
    required this.userId,
    required this.positions,
    required this.timestamp,
  });

  factory PositionUpdate.fromJson(Map<String, dynamic> json) {
    return PositionUpdate(
      userId: json['userId'] as String,
      positions: (json['positions'] as List)
          .map((p) => UserPosition.fromJson(p as Map<String, dynamic>))
          .toList(),
      timestamp: DateTime.parse(json['timestamp'] as String),
    );
  }
}

/// 位置サービスの状態
class PositionServiceState {
  final PositionConnectionState connectionState;
  final bool trilaterationEnabled;
  final Map<String, UserPosition> positions;
  final DateTime? lastUpdate;
  final int activeUsers;
  final String? fallbackReason;
  final bool compassEnabled;
  final double? currentHeading;

  const PositionServiceState({
    this.connectionState = PositionConnectionState.disconnected,
    this.trilaterationEnabled = false,
    this.positions = const {},
    this.lastUpdate,
    this.activeUsers = 0,
    this.fallbackReason,
    this.compassEnabled = false,
    this.currentHeading,
  });

  PositionServiceState copyWith({
    PositionConnectionState? connectionState,
    bool? trilaterationEnabled,
    Map<String, UserPosition>? positions,
    DateTime? lastUpdate,
    int? activeUsers,
    String? fallbackReason,
    bool? compassEnabled,
    double? currentHeading,
  }) {
    return PositionServiceState(
      connectionState: connectionState ?? this.connectionState,
      trilaterationEnabled: trilaterationEnabled ?? this.trilaterationEnabled,
      positions: positions ?? this.positions,
      lastUpdate: lastUpdate ?? this.lastUpdate,
      activeUsers: activeUsers ?? this.activeUsers,
      fallbackReason: fallbackReason,
      compassEnabled: compassEnabled ?? this.compassEnabled,
      currentHeading: currentHeading ?? this.currentHeading,
    );
  }
}

/// 位置サービスプロバイダー
@riverpod
class PositionService extends _$PositionService {
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  StreamSubscription<MagnetometerEvent>? _compassSubscription;
  Timer? _reconnectTimer;
  Timer? _rssiReportTimer;
  String? _userId;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 5;
  double? _lastHeading;

  @override
  PositionServiceState build() {
    ref.onDispose(() {
      _cleanup();
    });
    return const PositionServiceState();
  }

  void _cleanup() {
    _rssiReportTimer?.cancel();
    _rssiReportTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _subscription?.cancel();
    _subscription = null;
    _compassSubscription?.cancel();
    _compassSubscription = null;
    _channel?.sink.close();
    _channel = null;
  }

  /// WebSocket URLを取得
  String get _wsUrl {
    const baseUrl = AppDefaults.apiBaseUrl;
    // http(s)://xxx/api -> ws(s)://xxx/ws
    final wsBase = baseUrl
        .replaceFirst('https', 'wss')
        .replaceFirst('http', 'ws')
        .replaceFirst('/api', '');
    return '$wsBase/ws';
  }

  /// 接続を開始
  Future<void> connect(String userId) async {
    if (state.connectionState == PositionConnectionState.connected ||
        state.connectionState == PositionConnectionState.connecting) {
      return;
    }

    _userId = userId;
    state = state.copyWith(connectionState: PositionConnectionState.connecting);

    try {
      _channel = WebSocketChannel.connect(Uri.parse(_wsUrl));

      // 接続成功を待つ
      await _channel!.ready;

      state = state.copyWith(connectionState: PositionConnectionState.connected);
      _reconnectAttempts = 0;

      // ユーザー登録メッセージを送信
      _sendMessage({
        'type': 'register',
        'userId': userId,
      });

      // メッセージ受信を開始
      _subscription = _channel!.stream.listen(
        _handleMessage,
        onError: _handleError,
        onDone: _handleDone,
      );

      // RSSIレポート定期送信を開始
      _startRSSIReportTimer();
    } catch (e) {
      state = state.copyWith(connectionState: PositionConnectionState.disconnected);
      _scheduleReconnect();
    }
  }

  /// 切断
  Future<void> disconnect() async {
    _cleanup();
    _userId = null;
    state = const PositionServiceState();
  }

  /// RSSIデータを送信
  void sendRSSIReport(Set<DetectedUser> detectedUsers) {
    if (state.connectionState != PositionConnectionState.connected) {
      return;
    }

    final detectedList = detectedUsers.map((user) => {
      'userId': user.displayId,
      'rssi': user.rssi,
      'timestamp': user.lastSeen.toIso8601String(),
    }).toList();

    final message = <String, dynamic>{
      'type': 'rssi_report',
      'detectedUsers': detectedList,
    };

    // コンパスが有効な場合はheadingを追加
    if (state.compassEnabled && _lastHeading != null) {
      message['heading'] = _lastHeading;
    }

    _sendMessage(message);
  }

  /// コンパスを有効化
  void enableCompass() {
    if (state.compassEnabled) return;

    _compassSubscription = magnetometerEventStream().listen((event) {
      // 磁力計データから方位を計算 (x, yから角度を算出)
      // atan2(y, x) で北からの角度を取得
      final heading = _calculateHeading(event.x, event.y);
      _lastHeading = heading;
      state = state.copyWith(currentHeading: heading);
    });

    state = state.copyWith(compassEnabled: true);

    // サーバーにコンパス有効化を通知
    if (state.connectionState == PositionConnectionState.connected) {
      _sendMessage({
        'type': 'compass_enabled',
        'enabled': true,
      });
    }
  }

  /// コンパスを無効化
  void disableCompass() {
    if (!state.compassEnabled) return;

    _compassSubscription?.cancel();
    _compassSubscription = null;
    _lastHeading = null;

    state = state.copyWith(
      compassEnabled: false,
      currentHeading: null,
    );

    // サーバーにコンパス無効化を通知
    if (state.connectionState == PositionConnectionState.connected) {
      _sendMessage({
        'type': 'compass_enabled',
        'enabled': false,
      });
    }
  }

  /// コンパスの有効/無効を切り替え
  void toggleCompass() {
    if (state.compassEnabled) {
      disableCompass();
    } else {
      enableCompass();
    }
  }

  /// 磁力計データから方位を計算（0-360度、北が0）
  double _calculateHeading(double x, double y) {
    // atan2で角度を計算（ラジアン）
    var heading = atan2(-y, x) * (180 / pi);
    // 0-360の範囲に正規化
    if (heading < 0) {
      heading += 360;
    }
    return heading;
  }

  void _sendMessage(Map<String, dynamic> message) {
    if (_channel != null) {
      _channel!.sink.add(jsonEncode(message));
    }
  }

  void _handleMessage(dynamic data) {
    try {
      final message = jsonDecode(data as String) as Map<String, dynamic>;
      final type = message['type'] as String?;
      final payload = message['payload'] as Map<String, dynamic>?;

      switch (type) {
        case 'registered':
          if (payload != null) {
            state = state.copyWith(
              activeUsers: payload['activeUsers'] as int? ?? 0,
              trilaterationEnabled: payload['trilaterationEnabled'] as bool? ?? false,
            );
          }
          break;

        case 'position_update':
          if (payload != null) {
            final update = PositionUpdate.fromJson(payload);
            final newPositions = <String, UserPosition>{};
            for (final pos in update.positions) {
              newPositions[pos.targetUserId] = pos;
            }
            state = state.copyWith(
              positions: newPositions,
              lastUpdate: update.timestamp,
              trilaterationEnabled: true,
              fallbackReason: null,
            );
          }
          break;

        case 'fallback_mode':
          if (payload != null) {
            state = state.copyWith(
              trilaterationEnabled: false,
              fallbackReason: payload['reason'] as String?,
              activeUsers: payload['activeUsers'] as int? ?? 0,
            );
          }
          break;

        case 'user_joined':
        case 'user_left':
          // ユーザー参加/離脱は特に処理不要（次のposition_updateで更新される）
          break;

        case 'rssi_received':
          if (payload != null) {
            state = state.copyWith(
              activeUsers: payload['activeUsers'] as int? ?? state.activeUsers,
              trilaterationEnabled: payload['trilaterationEnabled'] as bool? ?? state.trilaterationEnabled,
            );
          }
          break;

        case 'error':
          // エラーメッセージをログに出力
          break;
      }
    } catch (e) {
      // パースエラー
    }
  }

  void _handleError(dynamic error) {
    state = state.copyWith(connectionState: PositionConnectionState.disconnected);
    _scheduleReconnect();
  }

  void _handleDone() {
    state = state.copyWith(connectionState: PositionConnectionState.disconnected);
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_userId == null || _reconnectAttempts >= _maxReconnectAttempts) {
      return;
    }

    _reconnectTimer?.cancel();

    // 指数バックオフ: 1秒, 2秒, 4秒, 8秒, 16秒
    final delay = Duration(seconds: 1 << _reconnectAttempts);
    _reconnectAttempts++;

    state = state.copyWith(connectionState: PositionConnectionState.reconnecting);

    _reconnectTimer = Timer(delay, () {
      if (_userId != null) {
        connect(_userId!);
      }
    });
  }

  void _startRSSIReportTimer() {
    _rssiReportTimer?.cancel();

    // 5秒間隔でRSSIデータを送信
    _rssiReportTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      final bleState = ref.read(bleServiceProvider);
      if (bleState.isSensing && bleState.detectedUsers.isNotEmpty) {
        sendRSSIReport(bleState.detectedUsers);
      }
    });
  }
}
