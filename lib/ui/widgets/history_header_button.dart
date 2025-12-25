import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 検知履歴ページへのナビゲーションと検知数表示を兼ねるヘッダーボタン
class HistoryHeaderButton extends StatelessWidget {
  const HistoryHeaderButton({
    super.key,
    required this.detectedCount,
    required this.onPressed,
  });

  /// 検知ユーザー数
  final int detectedCount;

  /// タップ時のコールバック
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.transparent,
          border: Border.all(
            color: AppTheme.border,
            width: 1,
          ),
        ),
        child: Center(
          child: Text(
            detectedCount > 99 ? '99+' : detectedCount.toString(),
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: detectedCount > 0 ? AppTheme.primary : AppTheme.textSecondary,
              fontSize: 16,
            ),
          ),
        ),
      ),
    );
  }
}
