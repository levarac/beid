import 'package:flutter/material.dart';

/// センシング開始/停止ボタン
class SensingButton extends StatelessWidget {
  const SensingButton({
    super.key,
    required this.isSensing,
    required this.isLoading,
    required this.onPressed,
    this.elapsedTime,
    this.enabled = true,
  });

  final bool isSensing;
  final bool isLoading;
  final VoidCallback onPressed;
  final String? elapsedTime;
  final bool enabled;

  static const Color _startButtonColor = Color(0xFFFF6000);
  static const Color _sensingButtonColor = Color(0xFF1A1A1A);

  @override
  Widget build(BuildContext context) {
    final buttonColor = isSensing ? _sensingButtonColor : _startButtonColor;

    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton(
        onPressed: (isLoading || !enabled) ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: buttonColor,
          foregroundColor: Colors.white,
          disabledBackgroundColor: buttonColor.withValues(alpha: 0.5),
          disabledForegroundColor: Colors.white.withValues(alpha: 0.7),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(56),
          ),
        ),
        child: isLoading
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Text(
                isSensing ? (elapsedTime ?? 'Sensing...') : 'Start Sensing',
                style: const TextStyle(
                  fontFamily: 'Silkscreen',
                  fontSize: 18,
                  fontWeight: FontWeight.w400,
                ),
              ),
      ),
    );
  }
}
