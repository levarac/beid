package org.levarac.beid.ui.screens

import android.view.View
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.hasScrollToIndexAction
import androidx.compose.ui.test.performScrollToIndex
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.core.graphics.Insets
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.test.core.app.ApplicationProvider
import java.time.Instant
import java.util.UUID
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.levarac.beid.R
import org.levarac.beid.navigation.HomeTab
import org.levarac.beid.persistence.ProofRecord
import org.levarac.beid.ui.theme.BeidAppTheme
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * Pushed routes with no Scaffold or `BeidScreen` must clear the system bars
 * themselves: targetSdk 36 draws edge-to-edge on Android 15+, so a plain
 * Column slides under the status bar and its last row under the navigation
 * bar.
 *
 * Robolectric does not lay the window out edge-to-edge, so each test hands the
 * composition's own view real `WindowInsetsCompat` through
 * [ViewCompat.dispatchApplyWindowInsets] — the path a device's window takes to
 * Compose's `WindowInsets` — and then measures where content lands. The
 * window is phone-sized (Pixel 7a is 412 x 891 dp) because Robolectric's
 * default 320 x 470 dp leaves almost no room once these deliberately large
 * bars are taken out.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "w412dp-h891dp-mdpi")
class PushedScreenInsetsTest {
    @get:Rule val compose = createComposeRule()

    private lateinit var view: View

    private fun show(content: @Composable () -> Unit) {
        compose.setContent {
            view = LocalView.current
            BeidAppTheme { content() }
        }
        compose.waitForIdle()
        compose.runOnUiThread {
            ViewCompat.dispatchApplyWindowInsets(
                view,
                WindowInsetsCompat.Builder()
                    .setInsets(WindowInsetsCompat.Type.systemBars(), Insets.of(0, STATUS_BAR_PX, 0, NAVIGATION_BAR_PX))
                    .build(),
            )
        }
        compose.waitForIdle()
    }

    private fun Dp.px(): Float = value * view.resources.displayMetrics.density

    private fun assertBelowStatusBar(text: Int) {
        val top = compose.onNodeWithText(ApplicationProvider.getApplicationContext<android.content.Context>().getString(text))
            .getUnclippedBoundsInRoot().top.px()
        assertTrue(top >= STATUS_BAR_PX, "title top $top px is under the $STATUS_BAR_PX px status bar")
    }

    private fun assertAboveNavigationBar(tag: String, lazyIndex: Int? = null) {
        if (lazyIndex != null) compose.onNode(hasScrollToIndexAction()).performScrollToIndex(lazyIndex)
        val node = compose.onNodeWithTag(tag).let { if (lazyIndex == null) it.performScrollTo() else it }
        val bottom = node.getUnclippedBoundsInRoot().bottom.px()
        val windowBottom = compose.onRoot().getUnclippedBoundsInRoot().bottom.px()
        assertTrue(
            bottom <= windowBottom - NAVIGATION_BAR_PX,
            "last row bottom $bottom px is under the navigation bar starting at ${windowBottom - NAVIGATION_BAR_PX} px",
        )
    }

    private fun records(count: Int) = (0 until count).map {
        ProofRecord(UUID.randomUUID(), "event-$it", Instant.ofEpochSecond(1_790_000_000L - it * 86_400L), 3)
    }

    @Test fun recordsByEventClearsTheSystemBars() {
        val groups = records(12).map { listOf(it) }
        show { RecordsByEventScreen(groups = groups, onOpenEventRecords = {}) }

        assertBelowStatusBar(R.string.records_by_event_title)
        assertAboveNavigationBar(RecordsHomeScreenTestTags.byEventRow(groups.last().first().id))
    }

    @Test fun todaySummaryClearsTheStatusBar() {
        show { TodaySummaryScreen(recordCount = 0) }

        assertBelowStatusBar(R.string.today_summary_title)
    }

    @Test fun recordsListClearsTheSystemBars() {
        val items = records(20).map { it.toRecordListItem() }
        show { RecordsScreen(records = items) }

        assertBelowStatusBar(R.string.records_title)
        assertAboveNavigationBar(RecordsScreenTestTags.recordRow(items.last().id), lazyIndex = items.lastIndex)
    }

    /**
     * Confirmation, not a fix: the Home shell's Scaffold (TopAppBar top
     * insets, NavigationBar bottom insets, content padded and consumed) keeps
     * Now and Records clear of both bars, and a screen rendered inside the
     * content slot that asks for the insets again gets nothing extra.
     */
    @Test fun homeShellClearsTheSystemBarsAndConsumesThem() {
        show {
            HomeContent(
                selectedTab = HomeTab.Now,
                onSelectTab = {},
                isSensing = false,
                onOpenAccount = {},
                onCloseScan = {},
                nowContent = { modifier ->
                    Box(modifier.fillMaxSize().testTag(SLOT)) {
                        Box(Modifier.windowInsetsPadding(WindowInsets.safeDrawing).size(1.dp).testTag(NESTED))
                    }
                },
                recordsContent = {},
            )
        }

        val windowBottom = compose.onRoot().getUnclippedBoundsInRoot().bottom.px()
        val account = compose.onNodeWithTag(EventJoinScreenTestTags.ACCOUNT_ENTRY).getUnclippedBoundsInRoot()
        assertTrue(account.top.px() >= STATUS_BAR_PX, "Account sits under the status bar")
        val slot = compose.onNodeWithTag(SLOT).getUnclippedBoundsInRoot()
        assertTrue(slot.top.px() >= STATUS_BAR_PX)
        assertTrue(slot.bottom.px() <= windowBottom - NAVIGATION_BAR_PX)
        val tab = compose.onNodeWithTag(HomeScreenTestTags.RECORDS_TAB).getUnclippedBoundsInRoot()
        assertTrue(tab.bottom.px() <= windowBottom - NAVIGATION_BAR_PX, "the tab bar sits under the navigation bar")
        assertEquals(slot.top, compose.onNodeWithTag(NESTED).getUnclippedBoundsInRoot().top, "insets applied twice")
    }

    /** Confirmation, not a fix: event-code entry's Scaffold clears both bars. */
    @Test fun codeEntryScaffoldClearsTheSystemBars() {
        show { ManualEventCodeContent(state = EventJoinScreenState(), onEventCodeChanged = {}, onSubmit = {}) }

        val back = compose.onNodeWithTag(EventJoinScreenTestTags.MANUAL_BACK_BUTTON).getUnclippedBoundsInRoot()
        assertTrue(back.top.px() >= STATUS_BAR_PX, "Back sits under the status bar")
        assertAboveNavigationBar(EventJoinScreenTestTags.SUBMIT_BUTTON)
    }

    private companion object {
        const val STATUS_BAR_PX = 200
        const val NAVIGATION_BAR_PX = 150
        const val SLOT = "insets_test_slot"
        const val NESTED = "insets_test_nested"
    }
}
