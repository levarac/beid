package org.levarac.beid.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.material3.Text
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.UUID
import org.levarac.beid.R
import org.levarac.beid.persistence.ProofRecord
import org.levarac.beid.persistence.ProofRecordStore
import org.levarac.beid.ui.theme.BeidAppTheme
import org.levarac.beid.ui.theme.BeidFont
import org.levarac.beid.ui.theme.BeidRadius
import org.levarac.beid.ui.theme.BeidSpacing
import org.levarac.beid.ui.theme.BeidTextStyle
import org.levarac.beid.ui.theme.BeidTheme

/** Compose test tags for [RecordsHomeScreen] and [RecordsByEventScreen]; not user-facing copy. */
object RecordsHomeScreenTestTags {
    const val ROOT = "records_home"
    /** On every Attendance tile's content, so tests can count tiles. */
    const val ATTENDANCE_TILE = "records_home_attendance_tile"
    const val BY_EVENT_CONTROL = "records_home_by_event"
    const val TODAY_CONTROL = "records_home_today"
    const val EMPTY_STATE = "records_home_empty_state"
    const val BY_EVENT_ROOT = "records_by_event"
    /** On every By event row's content, so tests can count rows. */
    const val BY_EVENT_ROW = "records_by_event_row"
    fun attendanceTile(id: UUID): String = "records_home_record_$id"
    fun byEventRow(id: UUID): String = "records_by_event_row_$id"
}

/**
 * The Records tab content, ported from iOS #795 `RecordsHomeView`
 * (`ios/Beid/Views/CollectionHomeView.swift` on `feat/ios-v2-now-records`).
 *
 * Records shows one Attendance per event (DESIGN.md, 1.1 screen
 * specification). The tile opens the newest session's record; the event's
 * other sessions stay reachable through BY EVENT → [RecordsByEventScreen] →
 * the existing EventRecords route. Grouping and its newest-first order are
 * shared's [homeProofRecordGroups] decision; nothing here re-decides them.
 *
 * Content only: the tab shell supplies the tab bar and any top bar. The large
 * title scrolls with the content, as iOS's `records.title` does.
 *
 * **Not ported:** the Sigil artwork (`RecordSigilSlot`) above each tile and
 * row. Android's records UI has no Sigil or placeholder yet, so nothing
 * stands in for it.
 *
 * **Android-only:** the TODAY control at the end. iOS #795 leaves Today
 * without an entry point; Android keeps one here, where main's iOS home
 * placed the same quiet text control (`collection.dailySummaryButton`).
 */
@Composable
fun RecordsHomeScreen(
    groups: List<List<ProofRecord>>,
    onOpenRecord: (UUID) -> Unit,
    onOpenByEvent: () -> Unit,
    onOpenToday: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .testTag(RecordsHomeScreenTestTags.ROOT)
            .fillMaxSize()
            .background(BeidTheme.colors.surfaceCanvas)
            .verticalScroll(rememberScrollState())
            .padding(horizontal = BeidSpacing.pageMargin, vertical = BeidSpacing.s),
        verticalArrangement = Arrangement.spacedBy(BeidSpacing.l),
    ) {
        // iOS passes the event-group count to both halves of records.header.counts.
        val count = groups.size
        StyledText(
            text = stringResource(
                R.string.records_home_counts,
                pluralStringResource(R.plurals.records_home_counts_records, count, count),
                pluralStringResource(R.plurals.records_home_counts_events, count, count),
            ),
            style = BeidFont.Library.labelMono10,
            color = BeidTheme.colors.textSecondary,
        )
        StyledText(
            text = stringResource(R.string.records_home_title),
            style = BeidFont.Library.display60,
            modifier = Modifier.semantics { heading() },
        )
        TextControl(
            title = stringResource(R.string.records_home_by_event),
            trailingGlyph = "→",
            accessibilityLabel = stringResource(R.string.records_home_by_event_accessibility),
            onClick = onOpenByEvent,
            modifier = Modifier
                .align(Alignment.End)
                .testTag(RecordsHomeScreenTestTags.BY_EVENT_CONTROL),
        )
        if (groups.isEmpty()) {
            EmptyBlock(Modifier.testTag(RecordsHomeScreenTestTags.EMPTY_STATE)) {
                StyledText(
                    text = stringResource(R.string.records_home_empty),
                    style = BeidFont.Library.body13,
                    color = BeidTheme.colors.textSecondary,
                )
            }
        } else {
            AttendanceGrid(groups, onOpenRecord)
        }
        TextControl(
            title = stringResource(R.string.records_home_today),
            onClick = onOpenToday,
            modifier = Modifier.testTag(RecordsHomeScreenTestTags.TODAY_CONTROL),
        )
    }
}

/**
 * Two columns, one at accessibility text sizes — iOS's
 * `dynamicTypeSize.isAccessibilitySize`. iOS's first accessibility size
 * scales body text by about 1.65×, so Android's 1.8× and 2.0× font scales
 * get one column and 1.5× keeps two.
 */
private const val SingleColumnFontScale = 1.65f

@Composable
private fun AttendanceGrid(groups: List<List<ProofRecord>>, onOpenRecord: (UUID) -> Unit) {
    val columns = if (LocalDensity.current.fontScale >= SingleColumnFontScale) 1 else 2
    Column(verticalArrangement = Arrangement.spacedBy(BeidSpacing.l)) {
        groups.chunked(columns).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(BeidSpacing.l)) {
                row.forEach { group ->
                    AttendanceTile(group, onOpenRecord, Modifier.weight(1f))
                }
                repeat(columns - row.size) { Spacer(Modifier.weight(1f)) }
            }
        }
    }
}

@Composable
private fun AttendanceTile(group: List<ProofRecord>, onOpenRecord: (UUID) -> Unit, modifier: Modifier) {
    val newest = group.first()
    val label = group.eventLabel()
    val description = stringResource(R.string.records_home_record_accessibility, label)
    Box(
        modifier = modifier
            .testTag(RecordsHomeScreenTestTags.attendanceTile(newest.id))
            .clickable(role = Role.Button) { onOpenRecord(newest.id) }
            .semantics { contentDescription = description },
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .testTag(RecordsHomeScreenTestTags.ATTENDANCE_TILE),
            verticalArrangement = Arrangement.spacedBy(BeidSpacing.s),
        ) {
            StyledText(stringResource(R.string.records_home_attendance), BeidFont.Library.title17)
            StyledText(
                text = label.uppercase(),
                style = BeidFont.Library.labelMono10,
                color = BeidTheme.colors.textSecondary,
            )
        }
    }
}

/**
 * The "By event" page iOS #795 pushes from BY EVENT: one row per event with
 * its name, newest session date and session count, each opening that event's
 * sessions (the existing EventRecords route), single-session events included.
 * Content only; the shell supplies the top bar and back.
 */
@Composable
fun RecordsByEventScreen(
    groups: List<List<ProofRecord>>,
    onOpenEventRecords: (UUID) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .testTag(RecordsHomeScreenTestTags.BY_EVENT_ROOT)
            .fillMaxSize()
            .background(BeidTheme.colors.surfaceCanvas)
            // A pushed route with no Scaffold: clear the system bars edge-to-edge
            // windows draw under, keeping the canvas behind them.
            .windowInsetsPadding(WindowInsets.safeDrawing)
            .verticalScroll(rememberScrollState())
            .padding(horizontal = BeidSpacing.pageMargin, vertical = BeidSpacing.s),
    ) {
        StyledText(
            text = stringResource(R.string.records_by_event_title),
            style = BeidFont.screenTitle,
            modifier = Modifier
                .padding(bottom = BeidSpacing.l)
                .semantics { heading() },
        )
        groups.forEachIndexed { index, group ->
            if (index > 0) Hairline()
            ByEventRow(group, onOpenEventRecords)
        }
    }
}

/** iOS `DS.Size.listRowMinHeight`, the `Row/List` minimum; Android has no shared token for it yet. */
private val ListRowMinHeight: Dp = 92.dp

private val byEventDateFormatter: DateTimeFormatter =
    DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withZone(ZoneId.systemDefault())

@Composable
private fun ByEventRow(group: List<ProofRecord>, onOpenEventRecords: (UUID) -> Unit) {
    val newest = group.first()
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(RecordsHomeScreenTestTags.byEventRow(newest.id))
            .clickable(role = Role.Button) { onOpenEventRecords(newest.id) }
            .heightIn(min = ListRowMinHeight),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BeidSpacing.m),
    ) {
        Column(
            modifier = Modifier
                .weight(1f)
                .testTag(RecordsHomeScreenTestTags.BY_EVENT_ROW),
            verticalArrangement = Arrangement.spacedBy(BeidSpacing.xs),
        ) {
            StyledText(group.eventLabel(), BeidFont.Library.title17)
            StyledText(
                text = byEventDateFormatter.format(newest.createdAt),
                style = BeidFont.Library.labelMono10,
                color = BeidTheme.colors.textSecondary,
            )
        }
        StyledText(
            text = pluralStringResource(R.plurals.records_by_event_sessions, group.size, group.size),
            style = BeidFont.Library.labelMono10,
        )
    }
}

/** A stored name from any session wins, as on Home; otherwise the newest session's readable code label. */
private fun List<ProofRecord>.eventLabel(): String =
    firstNotNullOfOrNull { it.eventName } ?: first().toRecordListItem().displayLabel

/** A Flat 2b Library style, case included (Mono labels render uppercase). */
@Composable
private fun StyledText(
    text: String,
    style: BeidTextStyle,
    modifier: Modifier = Modifier,
    color: Color = BeidTheme.colors.textPrimary,
) {
    Text(text = style.cased(text), style = style.textStyle, color = color, modifier = modifier)
}

/**
 * iOS `BeidTextControl`: a `Label/Mono 11` text control with an optional
 * trailing glyph, at least a minimum hit target in both directions. When a
 * glyph is drawn, [accessibilityLabel] replaces the visible text so the
 * glyph is never read aloud.
 */
@Composable
private fun TextControl(
    title: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    trailingGlyph: String? = null,
    accessibilityLabel: String? = null,
) {
    Box(
        modifier = modifier
            .defaultMinSize(minWidth = MinHitTarget, minHeight = MinHitTarget)
            .clickable(role = Role.Button, onClick = onClick)
            .then(
                if (accessibilityLabel != null) {
                    Modifier.semantics { contentDescription = accessibilityLabel }
                } else {
                    Modifier
                },
            ),
        // Start, not center: a label narrower than the hit target keeps the page's leading edge.
        contentAlignment = Alignment.CenterStart,
    ) {
        StyledText(
            text = listOfNotNull(title, trailingGlyph).joinToString(" "),
            style = BeidFont.Library.labelMono11,
        )
    }
}

/** Android's minimum touch target; iOS uses its own 44 pt (`DS.Size.minHitTarget`). */
private val MinHitTarget: Dp = BeidSpacing.xxl

/**
 * iOS `BeidEmptyBlock` (`Block/Empty`): a dashed hairline frame with the
 * content centered horizontally. A one-line message sits centered and a
 * wrapped one fills the width, leading-aligned, as in SwiftUI.
 */
@Composable
private fun EmptyBlock(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    val stroke = BeidTheme.colors.strokeEmptyState
    Box(
        modifier = modifier
            .fillMaxWidth()
            .drawBehind {
                val width = EmptyBlockStroke.toPx()
                val dash = EmptyBlockDash.toPx()
                val radius = BeidRadius.emptyBlock.toPx()
                drawRoundRect(
                    color = stroke,
                    topLeft = Offset(width / 2, width / 2),
                    size = Size(size.width - width, size.height - width),
                    cornerRadius = CornerRadius(radius, radius),
                    style = Stroke(width = width, pathEffect = PathEffect.dashPathEffect(floatArrayOf(dash, dash))),
                )
            }
            .padding(horizontal = BeidSpacing.l, vertical = BeidSpacing.emptyBlockVertical),
        contentAlignment = Alignment.Center,
    ) {
        content()
    }
}

/** iOS `DS.Size.hairline` and `DS.Size.emptyBlockDash`. */
private val EmptyBlockStroke: Dp = 1.dp
private val EmptyBlockDash: Dp = 4.dp

@Composable
private fun Hairline() {
    Box(
        Modifier
            .fillMaxWidth()
            .height(EmptyBlockStroke)
            .background(BeidTheme.colors.strokeHairline),
    )
}

/**
 * The Records tab: observes the store and groups through shared.
 *
 * As on iOS #795, the tab itself opens only an event's newest record; an
 * event's sessions are reached through BY EVENT → [RecordsByEventRoute].
 */
@Composable
fun RecordsHomeRoute(
    proofRecordStore: ProofRecordStore,
    onOpenRecord: (UUID) -> Unit,
    onOpenToday: () -> Unit,
    onOpenByEvent: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val groups = rememberRecordGroups(proofRecordStore)
    RecordsHomeScreen(
        groups = groups,
        onOpenRecord = onOpenRecord,
        onOpenByEvent = onOpenByEvent,
        onOpenToday = onOpenToday,
        modifier = modifier,
    )
}

/** The By event destination: observes the store and groups through shared. */
@Composable
fun RecordsByEventRoute(
    proofRecordStore: ProofRecordStore,
    onOpenEventRecords: (UUID) -> Unit,
    modifier: Modifier = Modifier,
) {
    RecordsByEventScreen(
        groups = rememberRecordGroups(proofRecordStore),
        onOpenEventRecords = onOpenEventRecords,
        modifier = modifier,
    )
}

/** Records has no active event to exclude: every saved event is listed. */
@Composable
private fun rememberRecordGroups(proofRecordStore: ProofRecordStore): List<List<ProofRecord>> {
    val records by proofRecordStore.recordsFlow.collectAsState()
    return remember(records) { homeProofRecordGroups(records, activeEventCode = null) }
}

@Preview(name = "Records home, empty", showBackground = true)
@Composable
private fun RecordsHomeEmptyPreview() {
    BeidAppTheme {
        RecordsHomeScreen(groups = emptyList(), onOpenRecord = {}, onOpenByEvent = {}, onOpenToday = {})
    }
}
