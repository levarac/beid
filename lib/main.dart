import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import 'data/models/sensing_record.dart';
import 'ui/screens/home_screen.dart';
import 'ui/theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 環境変数の読み込み（.envが無くてもエラーにしない）
  try {
    await dotenv.load(fileName: '.env');
  } catch (e) {
    // .envファイルが存在しない場合はデフォルト値を使用
  }

  // Hiveの初期化
  await Hive.initFlutter();

  // Hiveアダプターの登録
  Hive.registerAdapter(SensingStatusAdapter());
  Hive.registerAdapter(SensingRecordAdapter());

  runApp(
    const ProviderScope(
      child: BeidApp(),
    ),
  );
}

class BeidApp extends StatelessWidget {
  const BeidApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Beid App',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.system,
      home: const HomeScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
