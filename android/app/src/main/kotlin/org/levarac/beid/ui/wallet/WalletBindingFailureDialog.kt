package org.levarac.beid.ui.wallet

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import org.levarac.beid.R
import org.levarac.beid.sensing.WalletBindingFailure

@Composable
fun WalletBindingFailureDialog(
    failure: WalletBindingFailure,
    onRetry: () -> Unit,
    onClose: () -> Unit,
) {
    val reason = when (failure) {
        WalletBindingFailure.Declined -> R.string.wallet_error_declined
        WalletBindingFailure.NotConnected -> R.string.wallet_error_not_connected
        WalletBindingFailure.TimedOut -> R.string.wallet_error_timed_out
        WalletBindingFailure.VerificationFailed -> R.string.wallet_error_verification_failed
        WalletBindingFailure.SmartWalletUnsupported -> R.string.wallet_error_smart_wallet_unsupported
    }
    AlertDialog(
        onDismissRequest = onClose,
        title = { Text(stringResource(R.string.wallet_error_title)) },
        text = { Text(stringResource(reason)) },
        confirmButton = {
            TextButton(onClick = if (failure.retryable) onRetry else onClose) {
                Text(stringResource(if (failure.retryable) R.string.wallet_error_try_again else R.string.wallet_error_close))
            }
        },
    )
}
