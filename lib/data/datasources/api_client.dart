import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../core/core.dart';
import '../../providers/app_providers.dart';

part 'api_client.g.dart';

/// センシングレポートのリクエスト
class SensingReportRequest {
  const SensingReportRequest({
    required this.userUuid,
    required this.walletAddress,
    required this.partnerUuid,
    required this.timestamp,
    required this.rssi,
    required this.signature,
  });

  final String userUuid;
  final String walletAddress;
  final String partnerUuid;
  final DateTime timestamp;
  final int rssi;
  final String signature;

  Map<String, dynamic> toJson() => {
        'userUuid': userUuid,
        'walletAddress': walletAddress,
        'partnerUuid': partnerUuid,
        'timestamp': timestamp.toIso8601String(),
        'rssi': rssi,
        'signature': signature,
      };
}

/// センシングレポートのレスポンス
class SensingReportResponse {
  const SensingReportResponse({
    required this.reportId,
    required this.status,
    this.txHash,
    this.message,
  });

  final String reportId;
  final String status;
  final String? txHash;
  final String? message;

  factory SensingReportResponse.fromJson(Map<String, dynamic> json) {
    return SensingReportResponse(
      reportId: json['reportId'] as String,
      status: json['status'] as String,
      txHash: json['txHash'] as String?,
      message: json['message'] as String?,
    );
  }
}

/// センシングステータスのレスポンス
class SensingStatusResponse {
  const SensingStatusResponse({
    required this.reportId,
    required this.status,
    this.txHash,
    this.message,
  });

  final String reportId;
  final String status;
  final String? txHash;
  final String? message;

  factory SensingStatusResponse.fromJson(Map<String, dynamic> json) {
    return SensingStatusResponse(
      reportId: json['reportId'] as String,
      status: json['status'] as String,
      txHash: json['txHash'] as String?,
      message: json['message'] as String?,
    );
  }
}

/// Dioインスタンスプロバイダー
@riverpod
Dio dio(Ref ref) {
  final env = ref.watch(envProvider);

  final dio = Dio(BaseOptions(
    baseUrl: env.apiBaseUrl,
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 30),
    headers: {
      'Content-Type': 'application/json',
    },
  ));

  // ログインターセプター（デバッグ用）
  dio.interceptors.add(LogInterceptor(
    requestBody: true,
    responseBody: true,
  ));

  return dio;
}

/// APIクライアントプロバイダー
@riverpod
class ApiClient extends _$ApiClient {
  @override
  void build() {}

  Dio get _dio => ref.read(dioProvider);

  /// センシングレポートを送信する
  Future<Result<SensingReportResponse, AppError>> submitSensingReport(
    SensingReportRequest request,
  ) async {
    try {
      final response = await _dio.post(
        '/sensing/report',
        data: request.toJson(),
      );

      final data = response.data as Map<String, dynamic>;
      return Success(SensingReportResponse.fromJson(data));
    } on DioException catch (e, st) {
      return Failure(_mapDioError(e, st));
    } catch (e, st) {
      return Failure(ApiError(
        message: 'レポートの送信に失敗しました: $e',
        cause: e,
        stackTrace: st,
        type: ApiErrorType.unknown,
      ));
    }
  }

  /// センシングステータスを取得する
  Future<Result<SensingStatusResponse, AppError>> getSensingStatus(
    String reportId,
  ) async {
    try {
      final response = await _dio.get('/sensing/status/$reportId');

      final data = response.data as Map<String, dynamic>;
      return Success(SensingStatusResponse.fromJson(data));
    } on DioException catch (e, st) {
      return Failure(_mapDioError(e, st));
    } catch (e, st) {
      return Failure(ApiError(
        message: 'ステータスの取得に失敗しました: $e',
        cause: e,
        stackTrace: st,
        type: ApiErrorType.unknown,
      ));
    }
  }

  ApiError _mapDioError(DioException e, StackTrace st) {
    final statusCode = e.response?.statusCode;
    final message = e.response?.data?['message'] as String? ?? e.message;

    final type = switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout =>
        ApiErrorType.timeout,
      DioExceptionType.connectionError => ApiErrorType.network,
      DioExceptionType.badResponse => _mapStatusCodeToErrorType(statusCode),
      _ => ApiErrorType.unknown,
    };

    return ApiError(
      message: message ?? 'APIエラーが発生しました',
      cause: e,
      stackTrace: st,
      statusCode: statusCode,
      type: type,
    );
  }

  ApiErrorType _mapStatusCodeToErrorType(int? statusCode) {
    if (statusCode == null) return ApiErrorType.unknown;
    return switch (statusCode) {
      401 || 403 => ApiErrorType.unauthorized,
      400 || 422 => ApiErrorType.validation,
      _ when statusCode >= 500 => ApiErrorType.server,
      _ => ApiErrorType.unknown,
    };
  }
}
