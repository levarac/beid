package org.levarac.beid.ui.wallet

import android.content.Context
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.core.app.ApplicationProvider
import kotlin.test.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.levarac.beid.R
import org.levarac.beid.sensing.WalletBindingFailure
import org.levarac.beid.ui.theme.BeidAppTheme
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class WalletBindingFailureDialogTest {
    @get:Rule val compose = createComposeRule()
    private val context: Context get() = ApplicationProvider.getApplicationContext()

    @Test fun retryableFailureShowsReasonAndRetries() {
        var retries = 0
        compose.setContent {
            BeidAppTheme { WalletBindingFailureDialog(WalletBindingFailure.TimedOut, { retries++ }, {}) }
        }
        compose.onNodeWithText(context.getString(R.string.wallet_error_timed_out)).assertIsDisplayed()
        compose.onNodeWithText(context.getString(R.string.wallet_error_try_again)).performClick()
        assertEquals(1, retries)
    }

    @Test fun unsupportedWalletOffersCloseInsteadOfRetry() {
        var closes = 0
        compose.setContent {
            BeidAppTheme { WalletBindingFailureDialog(WalletBindingFailure.SmartWalletUnsupported, {}, { closes++ }) }
        }
        compose.onNodeWithText(context.getString(R.string.wallet_error_smart_wallet_unsupported)).assertIsDisplayed()
        compose.onNodeWithText(context.getString(R.string.wallet_error_close)).performClick()
        assertEquals(1, closes)
    }
}
