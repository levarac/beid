package org.levarac.beid.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import org.levarac.beid.R
import org.levarac.beid.sensing.EventJoinCoordinator
import org.levarac.beid.sensing.EventJoinUiState
import org.levarac.beid.ui.theme.BeidAppTheme
import org.levarac.beid.ui.theme.BeidRadius
import org.levarac.beid.ui.theme.BeidSpacing
import org.levarac.beid.ui.theme.BeidTheme

/**
 * Field-level validation error shown inline under the event-code field,
 * mirroring iOS's `EventCodeEntryView.errorMessage` (`ios/Beid/Views/
 * EventCodeEntryView.swift`) — same copy, same "clear on edit" behavior.
 *
 * [JoinFailed] has no producer yet: [EventJoinCoordinator]'s state machine
 * (`EventJoinUiState`) collapses every non-permission join outcome into
 * [EventJoinUiState.PermissionDenied] — it doesn't yet distinguish "the SDK
 * rejected this code" from "permission was denied" (see
 * `BarnardPermissionResult.Failed` in `EventJoinCoordinator.kt`). Wiring this
 * branch is a coordinator change (`EventJoinUiState` needs a distinct failure
 * case), which is out of this screen's scope — the case is kept here, sharing
 * the same rendering path as [EmptyCode], so the future wiring is a one-line
 * state change rather than new UI.
 */
private sealed class EventJoinFieldError {
    data object EmptyCode : EventJoinFieldError()
    data object JoinFailed : EventJoinFieldError()
}

@Composable
private fun EventJoinFieldError.message(): String = when (this) {
    EventJoinFieldError.EmptyCode -> stringResource(R.string.event_join_error_empty_code)
    EventJoinFieldError.JoinFailed -> stringResource(R.string.event_join_error_join_failed)
}

/**
 * Event-join screen — this scaffold's one working screen (task brief: "one
 * screen proving the SDK call compiles and runs"). Mirrors the manual-entry
 * event-join slice landing on iOS in parallel; a stub/simple version here is
 * intentional, not a placeholder for missing work.
 *
 * [coordinator] is owned by `MainActivity` (not created here) because
 * `BarnardEngine.requestPermissions` is Activity-driven on Android — the
 * hosting Activity must forward `onRequestPermissionsResult` into the same
 * engine instance for the request to ever resolve (see
 * android/vendor/barnard's README "Usage").
 */
@Composable
fun EventJoinScreen(coordinator: EventJoinCoordinator) {
    val uiState by coordinator.state.collectAsState()
    var eventCode by remember { mutableStateOf("") }
    var fieldError by remember { mutableStateOf<EventJoinFieldError?>(null) }

    fun submit() {
        if (eventCode.isBlank()) {
            fieldError = EventJoinFieldError.EmptyCode
            return
        }
        fieldError = null
        coordinator.joinEvent(eventCode)
    }

    Scaffold(containerColor = BeidTheme.colors.surfaceCanvas) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .padding(BeidSpacing.pageMargin),
            verticalArrangement = Arrangement.spacedBy(BeidSpacing.l, Alignment.CenterVertically),
        ) {
            Text(
                text = stringResource(R.string.event_join_title),
                style = MaterialTheme.typography.headlineLarge,
                color = BeidTheme.colors.textPrimary,
            )

            Column(verticalArrangement = Arrangement.spacedBy(BeidSpacing.s)) {
                OutlinedTextField(
                    value = eventCode,
                    onValueChange = {
                        eventCode = it
                        fieldError = null
                    },
                    label = { Text(stringResource(R.string.event_join_code_label)) },
                    isError = fieldError != null,
                    singleLine = true,
                    shape = RoundedCornerShape(BeidRadius.control),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedTextColor = BeidTheme.colors.textPrimary,
                        unfocusedTextColor = BeidTheme.colors.textPrimary,
                        errorTextColor = BeidTheme.colors.textPrimary,
                        focusedContainerColor = BeidTheme.colors.surfaceRaised,
                        unfocusedContainerColor = BeidTheme.colors.surfaceRaised,
                        errorContainerColor = BeidTheme.colors.surfaceRaised,
                        // iOS's EventCodeEntryView never varies the field's own border/label/
                        // cursor color on error — only the message below it changes — so the
                        // error variants mirror the unfocused/normal ones instead of Material3's
                        // stock red, keeping this control visually identical to iOS on error.
                        focusedBorderColor = BeidTheme.colors.actionPrimary,
                        unfocusedBorderColor = BeidTheme.colors.strokeHairline,
                        errorBorderColor = BeidTheme.colors.strokeHairline,
                        errorLabelColor = BeidTheme.colors.textSecondary,
                        cursorColor = BeidTheme.colors.actionPrimary,
                        errorCursorColor = BeidTheme.colors.actionPrimary,
                        errorSupportingTextColor = BeidTheme.colors.textPrimary,
                    ),
                    modifier = Modifier.fillMaxWidth(),
                )

                fieldError?.let { error ->
                    // iOS renders this row in DS.Color.textPrimary (plain ink), not a warning
                    // accent — DESIGN.md §5's accent map reserves signalWarning for BLE
                    // signal-loss recovery screens, and a validation/join error isn't that.
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(BeidSpacing.xs),
                    ) {
                        Text(
                            text = "⚠",
                            style = MaterialTheme.typography.bodyMedium,
                            color = BeidTheme.colors.textPrimary,
                        )
                        Text(
                            text = error.message(),
                            style = MaterialTheme.typography.bodyMedium,
                            color = BeidTheme.colors.textPrimary,
                        )
                    }
                }
            }

            Text(
                text = statusText(uiState),
                style = MaterialTheme.typography.bodyMedium,
                color = BeidTheme.colors.textSecondary,
            )

            when (uiState) {
                is EventJoinUiState.PermissionDenied -> {
                    BeidCtaButton(
                        text = stringResource(R.string.event_join_open_settings),
                        onClick = { coordinator.openAppSettings() },
                    )
                }
                else -> {
                    BeidCtaButton(
                        text = stringResource(R.string.event_join_button),
                        onClick = ::submit,
                        enabled = uiState !is EventJoinUiState.RequestingPermission,
                    )
                }
            }
        }
    }
}

/**
 * Primary-CTA button styling shared by this screen's two actions ("Join
 * event" and `PermissionDenied`'s "Open Settings") — mirrors iOS's
 * `BeidPrimaryButton` (`ios/Beid/DesignSystem.swift`): filled, full width,
 * [BeidRadius.control] corners, `DS.Font.cta`-equivalent label
 * ([MaterialTheme.typography.labelLarge], per `Type.kt`'s role mapping), and
 * `DS.Color.actionPrimary` tint — this screen has no sensing/ceremony/
 * recovery state per DESIGN.md §5's accent map, so the default tint applies
 * to both actions.
 */
@Composable
private fun BeidCtaButton(
    text: String,
    onClick: () -> Unit,
    enabled: Boolean = true,
) {
    Button(
        onClick = onClick,
        enabled = enabled,
        shape = RoundedCornerShape(BeidRadius.control),
        colors = ButtonDefaults.buttonColors(
            containerColor = BeidTheme.colors.actionPrimary,
            contentColor = BeidTheme.colors.surfaceCanvas,
        ),
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp),
    ) {
        Text(text, style = MaterialTheme.typography.labelLarge)
    }
}

@Composable
private fun statusText(state: EventJoinUiState): String = when (state) {
    is EventJoinUiState.Idle -> stringResource(R.string.event_join_status_idle)
    is EventJoinUiState.RequestingPermission -> stringResource(R.string.event_join_status_requesting_permission)
    is EventJoinUiState.Sensing -> stringResource(R.string.event_join_status_sensing)
    is EventJoinUiState.PermissionDenied -> stringResource(R.string.event_join_status_permission_denied)
}

@Preview(name = "Idle", showBackground = true)
@Composable
private fun EventJoinScreenPreview() {
    BeidAppTheme {
        Column(
            modifier = Modifier.padding(BeidSpacing.pageMargin),
            verticalArrangement = Arrangement.spacedBy(BeidSpacing.l),
        ) {
            Text(stringResource(R.string.event_join_title))
            Text(stringResource(R.string.event_join_status_idle))
        }
    }
}

@Preview(name = "Error — empty code", showBackground = true)
@Composable
private fun EventJoinScreenEmptyCodeErrorPreview() {
    BeidAppTheme {
        EventJoinFieldErrorPreview(EventJoinFieldError.EmptyCode)
    }
}

/**
 * Pins [EventJoinFieldError.JoinFailed]'s copy/visual even though it has no
 * live producer yet (see the kdoc on [EventJoinFieldError]) — Preview is the
 * only way to exercise it until [EventJoinCoordinator] gains a distinct
 * join-failure state.
 */
@Preview(name = "Error — join failed (dormant, see kdoc)", showBackground = true)
@Composable
private fun EventJoinScreenJoinFailedErrorPreview() {
    BeidAppTheme {
        EventJoinFieldErrorPreview(EventJoinFieldError.JoinFailed)
    }
}

@Composable
private fun EventJoinFieldErrorPreview(error: EventJoinFieldError) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(BeidSpacing.pageMargin),
        verticalArrangement = Arrangement.spacedBy(BeidSpacing.l),
    ) {
        Text(
            text = stringResource(R.string.event_join_title),
            style = MaterialTheme.typography.headlineLarge,
            color = BeidTheme.colors.textPrimary,
        )

        Column(verticalArrangement = Arrangement.spacedBy(BeidSpacing.s)) {
            OutlinedTextField(
                value = "",
                onValueChange = {},
                label = { Text(stringResource(R.string.event_join_code_label)) },
                isError = true,
                singleLine = true,
                shape = RoundedCornerShape(BeidRadius.control),
                colors = OutlinedTextFieldDefaults.colors(
                    errorBorderColor = BeidTheme.colors.strokeHairline,
                ),
                modifier = Modifier.fillMaxWidth(),
            )

            Row(horizontalArrangement = Arrangement.spacedBy(BeidSpacing.xs)) {
                Text(text = "⚠", color = BeidTheme.colors.textPrimary)
                Text(text = error.message(), color = BeidTheme.colors.textPrimary)
            }
        }

        BeidCtaButton(text = stringResource(R.string.event_join_button), onClick = {})
    }
}
