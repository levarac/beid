import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// マイページへのナビゲーションまたはウォレット接続を兼ねるヘッダーボタン
class MyPageHeaderButton extends StatelessWidget {
  const MyPageHeaderButton({
    super.key,
    required this.isWalletConnected,
    required this.onPressed,
  });

  /// ウォレット接続状態
  final bool isWalletConnected;

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
          color: isWalletConnected
              ? AppTheme.primary.withValues(alpha: 0.15)
              : Colors.transparent,
          border: Border.all(
            color: isWalletConnected ? AppTheme.primary : AppTheme.border,
            width: 1,
          ),
        ),
        child: Center(
          child: Icon(
            isWalletConnected ? Icons.person : Icons.person_outline,
            size: 20,
            color: isWalletConnected
                ? AppTheme.primary
                : AppTheme.textSecondary,
          ),
        ),
      ),
    );
  }
}
