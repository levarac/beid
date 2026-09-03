package org.levarac.beid.ui.screens

import android.content.Context
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.test.core.app.ApplicationProvider
import java.io.File
import java.time.Instant
import java.util.UUID
import kotlin.test.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.levarac.beid.R
import org.levarac.beid.persistence.ProofRecord
import org.levarac.beid.persistence.ProofRecordStore
import org.levarac.beid.ui.theme.BeidAppTheme
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * Robolectric-backed Compose test — same shape as [RecordsScreenTest], see
 * android/README.md "Testing" for why this runs as a JVM
 * `:app:testDebugUnitTest` test instead of an instrumented `androidTest`.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class RecordDetailScreenTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    @get:Rule
    val tempFolder = TemporaryFolder()

    private val context: Context get() = ApplicationProvider.getApplicationContext()

    private fun record(
        eventCode: String = "ETHTOKYO2026",
        peersVerified: Int = 3,
        hasSelfProof: Boolean = false,
        hasBinding: Boolean = false,
    ) = ProofRecord(
        id = UUID.randomUUID(),
        eventCode = eventCode,
        createdAt = Instant.parse("2026-01-01T00:00:00Z"),
        peersVerified = peersVerified,
        hasSelfProof = hasSelfProof,
        hasBinding = hasBinding,
    )

    private val recordedText get() = context.getString(R.string.record_detail_recorded)
    private val notYetAvailableText get() = context.getString(R.string.record_detail_not_yet_available)

    @Test
    fun rendersEventCodeAndDevicesSensedFromTheRecord() {
        val record = record(eventCode = "DEVCON-SEA", peersVerified = 5)

        composeTestRule.setContent {
            BeidAppTheme { RecordDetailScreen(record = record) }
        }

        composeTestRule.onNodeWithText("DEVCON-SEA").assertIsDisplayed()
        composeTestRule.onNodeWithText("5").assertIsDisplayed()
    }

    @Test
    fun selfProofAndBindingRowsShowNotYetAvailableWhenAbsent() {
        val record = record(hasSelfProof = false, hasBinding = false)

        composeTestRule.setContent {
            BeidAppTheme { RecordDetailScreen(record = record) }
        }

        composeTestRule.onNodeWithTag(RecordDetailScreenTestTags.SELF_PROOF_VALUE)
            .assertTextEquals(notYetAvailableText)
        composeTestRule.onNodeWithTag(RecordDetailScreenTestTags.BINDING_VALUE)
            .assertTextEquals(notYetAvailableText)
    }

    @Test
    fun selfProofRowShowsRecordedOnceASelfProofExists() {
        val record = record(hasSelfProof = true, hasBinding = false)

        composeTestRule.setContent {
            BeidAppTheme { RecordDetailScreen(record = record) }
        }

        composeTestRule.onNodeWithTag(RecordDetailScreenTestTags.SELF_PROOF_VALUE).assertTextEquals(recordedText)
        composeTestRule.onNodeWithTag(RecordDetailScreenTestTags.BINDING_VALUE).assertTextEquals(notYetAvailableText)
    }

    @Test
    fun bindingRowShowsRecordedOnceABindingExists() {
        val record = record(hasSelfProof = true, hasBinding = true)

        composeTestRule.setContent {
            BeidAppTheme { RecordDetailScreen(record = record) }
        }

        composeTestRule.onNodeWithTag(RecordDetailScreenTestTags.BINDING_VALUE).assertTextEquals(recordedText)
    }

    /**
     * Parity with iOS's `ParticipationSummaryView.mutualCountUnavailableText`, which is also
     * unconditional (beid#222): mutual/reciprocal confirmation is structurally unmeasurable
     * on-device, never a real value regardless of the record's own state.
     */
    @Test
    fun mutualConfirmationRowIsAlwaysNotYetAvailableRegardlessOfSignatureState() {
        val fullySigned = record(hasSelfProof = true, hasBinding = true)

        composeTestRule.setContent {
            BeidAppTheme { RecordDetailScreen(record = fullySigned) }
        }

        composeTestRule.onNodeWithTag(RecordDetailScreenTestTags.MUTUAL_CONFIRMATION_VALUE)
            .assertTextEquals(notYetAvailableText)
    }

    /** beid#327: Android has no aggregation producer yet, so this section always renders the gap state. */
    @Test
    fun timeBandBuildupRowIsAlwaysNotYetAvailable() {
        val record = record()

        composeTestRule.setContent {
            BeidAppTheme { RecordDetailScreen(record = record) }
        }

        composeTestRule.onNodeWithTag(RecordDetailScreenTestTags.TIME_BAND_BUILDUP_VALUE)
            .assertTextEquals(notYetAvailableText)
    }

    @Test
    fun neverDisplaysAVerifiedClaimAnywhereOnTheScreen() {
        val record = record(hasSelfProof = true, hasBinding = true)

        composeTestRule.setContent {
            BeidAppTheme { RecordDetailScreen(record = record) }
        }

        composeTestRule.onNodeWithText("Verified", substring = true, ignoreCase = true).assertDoesNotExist()
    }

    /**
     * Defensive handling (beid#122): this app never deletes records, so a stale/bad
     * [recordId] should not normally happen — but [RecordDetailRoute] must not crash on
     * one; it calls [onRecordNotFound] instead of rendering anything.
     */
    @Test
    fun routeCallsOnRecordNotFoundExactlyOnceForAnUnknownRecordId() {
        val store = ProofRecordStore(File(tempFolder.root, "proof-records-v1.json"))
        store.add(record(eventCode = "OTHER"))
        var notFoundCallCount = 0

        composeTestRule.setContent {
            BeidAppTheme {
                RecordDetailRoute(
                    proofRecordStore = store,
                    recordId = UUID.randomUUID(),
                    onRecordNotFound = { notFoundCallCount += 1 },
                )
            }
        }

        composeTestRule.waitForIdle()
        assertEquals(1, notFoundCallCount)
    }

    @Test
    fun routeRendersTheMatchingRecordWhenTheIdIsKnown() {
        val store = ProofRecordStore(File(tempFolder.root, "proof-records-v1.json"))
        val target = record(eventCode = "DEVCON-SEA")
        store.add(target)

        composeTestRule.setContent {
            BeidAppTheme {
                RecordDetailRoute(proofRecordStore = store, recordId = target.id, onRecordNotFound = {})
            }
        }

        composeTestRule.onNodeWithText("DEVCON-SEA").assertIsDisplayed()
    }
}
