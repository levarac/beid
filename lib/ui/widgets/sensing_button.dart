import 'package:flutter/material.dart';

/// センシング開始/停止ボタン
class SensingButton extends StatelessWidget {
  const SensingButton({
    super.key,
    required this.isSensing,
    required this.isLoading,
    required this.onPressed,
  });

  final bool isSensing;
  final bool isLoading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton.extended(
      onPressed: isLoading ? null : onPressed,
      backgroundColor: isSensing
          ? Theme.of(context).colorScheme.error
          : Theme.of(context).colorScheme.primary,
      foregroundColor: isSensing
          ? Theme.of(context).colorScheme.onError
          : Theme.of(context).colorScheme.onPrimary,
      icon: isLoading
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : Icon(isSensing ? Icons.stop : Icons.play_arrow),
      label: Text(isLoading
          ? '処理中...'
          : isSensing
              ? 'センシング停止'
              : 'センシング開始'),
    );
  }
}
