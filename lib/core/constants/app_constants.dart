/// アプリケーション定数
class AppConstants {
  AppConstants._();

  /// BLE関連定数
  static const String bleServiceUuidPrefix = 'beid';
  static const Duration bleScanDuration = Duration(seconds: 10);
  static const Duration bleAdvertiseDuration = Duration(seconds: 30);

  /// センシング関連定数
  static const Duration sensingTimeWindow = Duration(minutes: 5);
  static const int minRssiThreshold = -80; // dBm

  /// ストレージ関連定数
  static const String sensingHistoryBoxName = 'sensing_history';
  static const String userSettingsBoxName = 'user_settings';
  static const Duration historyRetentionPeriod = Duration(days: 30);

  /// API関連定数
  static const Duration apiTimeout = Duration(seconds: 30);
  static const int maxRetryAttempts = 3;

  /// ウォレット関連定数
  static const int gnosisChainId = 100;
  static const String gnosisChainName = 'Gnosis';
}
