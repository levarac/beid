import 'package:flutter/material.dart';

import '../../services/wallet/wallet_service.dart';

/// ウォレット接続ボタン
class WalletButton extends StatelessWidget {
  const WalletButton({
    super.key,
    required this.walletState,
    required this.onPressed,
  });

  final WalletServiceState walletState;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    if (walletState.connectionState == WalletConnectionState.connecting) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    if (walletState.isConnected) {
      return TextButton.icon(
        onPressed: onPressed,
        icon: const Icon(Icons.account_balance_wallet, size: 18),
        label: Text(walletState.shortAddress ?? ''),
      );
    }

    return TextButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.account_balance_wallet_outlined, size: 18),
      label: const Text('接続'),
    );
  }
}
