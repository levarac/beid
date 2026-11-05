package org.levarac.beid.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import org.levarac.beid.R
import org.levarac.beid.sensing.ScanEventSession
import org.levarac.beid.sensing.ScanSessionMetrics
import org.levarac.beid.ui.designsystem.BeidPrimaryButton
import org.levarac.beid.ui.theme.BeidSpacing
import org.levarac.beid.ui.theme.BeidTheme

/** iOS 05e's content order and copy, using the scan flow's native theme and controls. */
@Composable
fun SensingStopConfirmScreen(
    event: ScanEventSession,
    metrics: ScanSessionMetrics,
    onStop: () -> Unit,
    onKeepSensing: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val locale = LocalConfiguration.current.locales[0]
    BoxWithConstraints(modifier.fillMaxSize().background(BeidTheme.colors.surfaceCanvas)) {
        val minimumHeight = maxHeight
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState())
                .heightIn(min = minimumHeight)
                .padding(horizontal = BeidSpacing.pageMargin, vertical = BeidSpacing.l)
                .testTag("scan.stop-confirm"),
        ) {
            event.eventName?.let { name ->
                Text(
                    name,
                    style = MaterialTheme.typography.displayMedium,
                    color = BeidTheme.colors.textPrimary,
                    modifier = Modifier.widthIn(max = 220.dp).semantics { heading() },
                )
            }
            metrics.firstSightingAt?.let { instant ->
                val time = DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT)
                    .withLocale(locale).withZone(ZoneId.systemDefault()).format(instant)
                Text(
                    stringResource(R.string.scan_stop_since, time),
                    style = MaterialTheme.typography.bodyMedium,
                    color = BeidTheme.colors.textSecondary,
                    modifier = Modifier.padding(top = BeidSpacing.s),
                )
            }
            Spacer(Modifier.weight(1f).heightIn(min = BeidSpacing.xxl))
            Text(
                stringResource(R.string.scan_stop_heading),
                style = MaterialTheme.typography.titleLarge,
                color = BeidTheme.colors.textPrimary,
            )
            Text(
                stringResource(R.string.scan_stop_message),
                style = MaterialTheme.typography.bodyMedium,
                color = BeidTheme.colors.textSecondary,
                modifier = Modifier.padding(top = BeidSpacing.s),
            )
            Text(
                stringResource(R.string.scan_stop_so_far),
                style = MaterialTheme.typography.labelSmall,
                color = BeidTheme.colors.textSecondary,
                modifier = Modifier.padding(top = BeidSpacing.xxl),
            )
            Row(Modifier.fillMaxWidth().padding(top = BeidSpacing.s)) {
                listOf(
                    R.string.scan_stop_mutual to metrics.mutualDeviceCount,
                    R.string.scan_stop_detected to metrics.detectedDeviceCount,
                    R.string.scan_stop_windows to metrics.windowCount,
                ).forEach { (label, value) ->
                    Column(Modifier.weight(1f)) {
                        Text(
                            value.toString(),
                            style = MaterialTheme.typography.displaySmall,
                            color = BeidTheme.colors.textPrimary,
                        )
                        Text(
                            stringResource(label),
                            style = MaterialTheme.typography.labelSmall,
                            color = BeidTheme.colors.textSecondary,
                            modifier = Modifier.padding(top = BeidSpacing.xs),
                        )
                    }
                }
            }
            Spacer(Modifier.weight(1f).heightIn(min = BeidSpacing.xxl))
            BeidPrimaryButton(
                text = stringResource(R.string.scan_stop_confirm),
                containerColor = BeidTheme.colors.actionPrimary,
                contentColor = BeidTheme.colors.surfaceCanvas,
                onClick = onStop,
                modifier = Modifier.testTag("scan.stop-confirm.stop"),
            )
            Spacer(Modifier.height(BeidSpacing.l))
            TextButton(onClick = onKeepSensing, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.scan_stop_keep_sensing), color = BeidTheme.colors.textPrimary)
            }
        }
    }
}
