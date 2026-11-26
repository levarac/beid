package org.levarac.beid.ui.screens

import android.content.Context
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.core.app.ApplicationProvider
import java.io.File
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.UUID
import kotlin.test.assertEquals
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.levarac.beid.persistence.ProofRecord
import org.levarac.beid.persistence.ProofRecordStore
import org.levarac.beid.ui.theme.BeidAppTheme
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * The Records tab content (iOS #795 `RecordsHomeView`) and its "By event"
 * page, driven through the production routes with a real [ProofRecordStore]
 * so the shared event grouping is exercised, not restated.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class RecordsHomeScreenTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private lateinit var store: ProofRecordStore

    @Before fun prepare() {
        val file = File(context.cacheDir, "records-home-test.json")
        check(!file.exists() || file.delete())
        store = ProofRecordStore(file)
    }

    private fun record(index: Int, code: String, date: String, name: String?) = ProofRecord(
        id = UUID.fromString("00000000-0000-0000-0000-%012d".format(index)),
        eventCode = code,
        createdAt = Instant.parse(date),
        peersVerified = 1,
        eventName = name,
    ).also(store::add)

    /** Three events; "Design review" has three sessions, stored oldest first. */
    private fun seed(): List<ProofRecord> = listOf(
        record(4, "design-review", "2026-10-23T13:00:00Z", "Design review"),
        record(1, "morning-meetup", "2026-10-24T09:30:00Z", "Morning meetup"),
        record(3, " DESIGN-REVIEW ", "2026-10-23T14:30:00Z", "Design review"),
        record(2, "design-review", "2026-10-23T15:45:00Z", "Design review"),
        record(5, "community-workshop", "2026-10-21T11:00:00Z", "Community workshop"),
    )

    private val opened = mutableListOf<String>()

    private fun setHome() {
        composeTestRule.setContent {
            BeidAppTheme {
                RecordsHomeRoute(
                    proofRecordStore = store,
                    onOpenRecord = { opened += "record:$it" },
                    onOpenToday = { opened += "today" },
                    onOpenByEvent = { opened += "byEvent" },
                )
            }
        }
    }

    private fun setByEvent() {
        composeTestRule.setContent {
            BeidAppTheme {
                RecordsByEventRoute(
                    proofRecordStore = store,
                    onOpenEventRecords = { opened += "event:$it" },
                )
            }
        }
    }

    private fun id(index: Int): UUID = UUID.fromString("00000000-0000-0000-0000-%012d".format(index))

    @Test
    fun showsOneAttendanceTilePerEventAndEachOpensItsNewestSession() {
        seed()
        setHome()

        composeTestRule.onNodeWithTag(RecordsHomeScreenTestTags.ROOT).assertIsDisplayed()
        composeTestRule.onAllNodesWithTag(RecordsHomeScreenTestTags.ATTENDANCE_TILE, useUnmergedTree = true)
            .assertCountEquals(3)
        // Older sessions of "Design review" have no tile of their own.
        composeTestRule.onNodeWithTag(RecordsHomeScreenTestTags.attendanceTile(id(3))).assertDoesNotExist()
        composeTestRule.onNodeWithTag(RecordsHomeScreenTestTags.attendanceTile(id(4))).assertDoesNotExist()

        composeTestRule.onNodeWithTag(RecordsHomeScreenTestTags.attendanceTile(id(2))).performScrollTo().performClick()
        assertEquals(listOf("record:${id(2)}"), opened)
    }

    @Test
    fun attendanceTileCarriesTheIosCopyAndAccessibilityLabel() {
        seed()
        setHome()

        composeTestRule.onNodeWithTag(RecordsHomeScreenTestTags.attendanceTile(id(2)))
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.ContentDescription, listOf("Record for Design review")))
        composeTestRule.onAllNodesWithText("Attendance", useUnmergedTree = true).assertCountEquals(3)
        composeTestRule.onNodeWithText("DESIGN REVIEW", useUnmergedTree = true).assertExists()
    }

    @Test
    fun headerCountsEventGroupsLikeIos() {
        seed()
        setHome()

        composeTestRule.onNodeWithText("3 RECORDS · 3 EVENTS").assertIsDisplayed()
        composeTestRule.onNodeWithText("Records").assertIsDisplayed()
    }

    @Test
    fun byEventControlOpensTheByEventDestination() {
        seed()
        setHome()

        composeTestRule.onNodeWithTag(RecordsHomeScreenTestTags.BY_EVENT_CONTROL)
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.ContentDescription, listOf("Records by event")))
            .performClick()
        assertEquals(listOf("byEvent"), opened)
    }

    @Test
    fun emptyStateUsesTheIosCopyAndKeepsByEventAndToday() {
        setHome()

        composeTestRule.onNodeWithTag(RecordsHomeScreenTestTags.EMPTY_STATE).assertIsDisplayed()
        composeTestRule.onNodeWithText("Saved records appear here after sensing.").assertIsDisplayed()
        composeTestRule.onNodeWithText("0 RECORDS · 0 EVENTS").assertIsDisplayed()
        composeTestRule.onAllNodesWithTag(RecordsHomeScreenTestTags.ATTENDANCE_TILE, useUnmergedTree = true)
            .assertCountEquals(0)
        composeTestRule.onNodeWithTag(RecordsHomeScreenTestTags.BY_EVENT_CONTROL).assertIsDisplayed()
        composeTestRule.onNodeWithTag(RecordsHomeScreenTestTags.TODAY_CONTROL).assertIsDisplayed()
    }

    @Test
    fun todayStaysReachableFromRecords() {
        seed()
        setHome()

        composeTestRule.onNodeWithTag(RecordsHomeScreenTestTags.TODAY_CONTROL).performScrollTo().performClick()
        assertEquals(listOf("today"), opened)
    }

    @Test
    fun byEventPageListsOneRowPerEventAndOpensItsSessions() {
        seed()
        setByEvent()

        composeTestRule.onNodeWithTag(RecordsHomeScreenTestTags.BY_EVENT_ROOT).assertIsDisplayed()
        composeTestRule.onNodeWithText("By event").assertIsDisplayed()
        composeTestRule.onAllNodesWithTag(RecordsHomeScreenTestTags.BY_EVENT_ROW, useUnmergedTree = true)
            .assertCountEquals(3)
        composeTestRule.onNodeWithText("3 SESSIONS →", useUnmergedTree = true).assertExists()
        composeTestRule.onAllNodesWithText("1 SESSION →", useUnmergedTree = true).assertCountEquals(2)
        // The newest session's date, in the device zone and the localized medium date form.
        val newestDate = DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withZone(ZoneId.systemDefault())
            .format(Instant.parse("2026-10-23T15:45:00Z")).uppercase()
        composeTestRule.onNode(
            hasText(newestDate) and hasAnyAncestor(hasTestTag(RecordsHomeScreenTestTags.byEventRow(id(2)))),
            useUnmergedTree = true,
        ).assertExists()

        composeTestRule.onNodeWithTag(RecordsHomeScreenTestTags.byEventRow(id(2))).performScrollTo().performClick()
        // Single-session events also open their sessions, as iOS's list always pushes EventDetailView.
        composeTestRule.onNodeWithTag(RecordsHomeScreenTestTags.byEventRow(id(5))).performScrollTo().performClick()
        assertEquals(listOf("event:${id(2)}", "event:${id(5)}"), opened)
    }

    @Test
    fun recordsAddedLaterAppearWithoutRecomposingTheCaller() {
        setHome()
        composeTestRule.onNodeWithTag(RecordsHomeScreenTestTags.EMPTY_STATE).assertIsDisplayed()

        record(9, "late-event", "2026-10-25T10:00:00Z", "Late event")
        composeTestRule.waitForIdle()

        composeTestRule.onNodeWithTag(RecordsHomeScreenTestTags.EMPTY_STATE).assertDoesNotExist()
        composeTestRule.onNodeWithTag(RecordsHomeScreenTestTags.attendanceTile(id(9))).assertIsDisplayed()
    }
}
