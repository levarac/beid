/// アプリケーションエラーの基底クラス
sealed class AppError {
  const AppError({
    required this.message,
    this.cause,
    this.stackTrace,
  });

  final String message;
  final Object? cause;
  final StackTrace? stackTrace;

  @override
  String toString() => 'AppError: $message';
}

/// BLE関連のエラー
final class BleError extends AppError {
  const BleError({
    required super.message,
    super.cause,
    super.stackTrace,
    this.type = BleErrorType.unknown,
  });

  final BleErrorType type;

  @override
  String toString() => 'BleError(${type.name}): $message';
}

enum BleErrorType {
  /// Bluetoothが無効
  bluetoothDisabled,

  /// パーミッションが拒否された
  permissionDenied,

  /// スキャンに失敗
  scanFailed,

  /// アドバタイズに失敗
  advertiseFailed,

  /// 接続に失敗
  connectionFailed,

  /// 不明なエラー
  unknown,
}

/// ウォレット関連のエラー
final class WalletError extends AppError {
  const WalletError({
    required super.message,
    super.cause,
    super.stackTrace,
    this.type = WalletErrorType.unknown,
  });

  final WalletErrorType type;

  @override
  String toString() => 'WalletError(${type.name}): $message';
}

enum WalletErrorType {
  /// 接続に失敗
  connectionFailed,

  /// 署名がキャンセルされた
  signatureCancelled,

  /// 署名に失敗
  signatureFailed,

  /// セッションが切れた
  sessionExpired,

  /// ネットワークエラー
  networkError,

  /// 不明なエラー
  unknown,
}

/// API関連のエラー
final class ApiError extends AppError {
  const ApiError({
    required super.message,
    super.cause,
    super.stackTrace,
    this.statusCode,
    this.type = ApiErrorType.unknown,
  });

  final int? statusCode;
  final ApiErrorType type;

  @override
  String toString() => 'ApiError(${type.name}, $statusCode): $message';
}

enum ApiErrorType {
  /// ネットワークエラー
  network,

  /// タイムアウト
  timeout,

  /// サーバーエラー
  server,

  /// 認証エラー
  unauthorized,

  /// バリデーションエラー
  validation,

  /// 不明なエラー
  unknown,
}

/// ストレージ関連のエラー
final class StorageError extends AppError {
  const StorageError({
    required super.message,
    super.cause,
    super.stackTrace,
    this.type = StorageErrorType.unknown,
  });

  final StorageErrorType type;

  @override
  String toString() => 'StorageError(${type.name}): $message';
}

enum StorageErrorType {
  /// 読み取りに失敗
  readFailed,

  /// 書き込みに失敗
  writeFailed,

  /// 削除に失敗
  deleteFailed,

  /// 不明なエラー
  unknown,
}
