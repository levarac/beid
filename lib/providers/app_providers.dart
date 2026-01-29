import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

/// デフォルト設定値
class AppDefaults {
  static const String apiBaseUrl = 'https://7eb02607c8c9.ngrok-free.app/api';
}

/// 環境変数プロバイダー
final envProvider = Provider<Env>((ref) {
  return Env();
});

/// 環境変数アクセスクラス
class Env {
  String get reownProjectId => dotenv.env['REOWN_PROJECT_ID'] ?? '';
  String get apiBaseUrl =>
      dotenv.env['API_BASE_URL'] ?? AppDefaults.apiBaseUrl;
}
