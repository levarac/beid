package org.levarac.beid.ui.screens

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.unit.Density
import java.io.File
import java.util.UUID
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.levarac.beid.persistence.ProofRecord
import org.levarac.beid.persistence.ProofRecordStore
import org.levarac.beid.sensing.ProofRecordingBridge
import org.levarac.beid.sensing.ScanEventSession
import org.levarac.beid.ui.theme.BeidAppTheme
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class RecordEventIdentityScreenTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    @get:Rule
    val tempFolder = TemporaryFolder()

    private fun reloadedRecord(name: String = EVENT_NAME): ProofRecord {
        val file = File(tempFolder.root, "records.json")
        ProofRecordingBridge(ProofRecordStore(file)).onProofCollected(
            UUID.randomUUID(), ScanEventSession(EVENT_ID, name, EVENT_ID), 3,
        )
        return ProofRecordStore(file).records.single()
    }

    @Test
    fun recordsListShowsTheStoredNameAfterReload() {
        val record = reloadedRecord()
        composeTestRule.setContent {
            BeidAppTheme { RecordsScreen(listOf(record.toRecordListItem())) }
        }
        composeTestRule.onNodeWithText(EVENT_NAME).assertIsDisplayed()
    }

    @Test
    fun aNameThatLooksLikeAnIdentifierIsNotAbbreviated() {
        val name = "ab".repeat(32)
        val record = reloadedRecord(name)
        composeTestRule.setContent {
            BeidAppTheme { RecordsScreen(listOf(record.toRecordListItem())) }
        }
        composeTestRule.onNodeWithText(name).assertIsDisplayed()
    }

    @Test
    fun recordDetailShowsTheStoredNameAndCanonicalIdentifier() {
        val record = reloadedRecord()
        composeTestRule.setContent {
            BeidAppTheme { RecordDetailScreen(record) }
        }
        composeTestRule.onNodeWithText(EVENT_NAME).assertIsDisplayed()
        composeTestRule.onNodeWithText(EVENT_ID).assertIsDisplayed()
    }

    @Test
    fun recordingShowsTheNameDuringAndAfterTheCeremonyAtLargeFontSize() {
        composeTestRule.mainClock.autoAdvance = false
        composeTestRule.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, 2f)) {
                BeidAppTheme {
                    Column(Modifier.verticalScroll(rememberScrollState())) {
                        RecordingScreen(
                            session = ScanEventSession(EVENT_ID, EVENT_NAME, EVENT_ID),
                            peersVerified = 3,
                            showEntranceCeremony = true,
                            onCeremonyFinished = {},
                            onSimulateSignalLost = {},
                            onStartWalletBinding = {},
                            ceremonyDwellMillis = 100,
                        )
                    }
                }
            }
        }
        composeTestRule.onNodeWithText(EVENT_NAME).assertIsDisplayed()
        composeTestRule.mainClock.advanceTimeBy(200)
        composeTestRule.onNodeWithText(EVENT_NAME).performScrollTo().assertIsDisplayed()
        composeTestRule.onNodeWithText("3").performScrollTo().assertIsDisplayed()
    }

    private companion object {
        const val EVENT_NAME = "Evening Gathering"
        const val EVENT_ID = "5d5891b92a9a6597aa2c58586fd2fdf3974f40f732b9a319ec9f3fc4d7ab3195"
    }
}
