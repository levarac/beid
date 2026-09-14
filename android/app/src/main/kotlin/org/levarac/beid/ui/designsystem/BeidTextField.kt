package org.levarac.beid.ui.designsystem

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import org.levarac.beid.ui.theme.BeidRadius
import org.levarac.beid.ui.theme.BeidTheme
import androidx.compose.foundation.text.KeyboardOptions

/**
 * Single-line text entry field — matches iOS's plain `TextField(_:prompt:)`
 * look (`ios/Beid/Views/EventCodeEntryView.swift`): a placeholder that
 * disappears on input and a plain, continuous border, not Material3's
 * floating-label/notched-border affordance.
 *
 * Uses [OutlinedTextField]'s `placeholder` slot instead of `label` — the
 * notch cut into the border is only drawn to make room for a floating
 * `label`, so a field with no `label` (placeholder only) renders a plain
 * unbroken outline, which is the iOS look this component targets. A
 * persistent field label, if one is ever needed, should be a separate
 * [Text] rendered above the field by the caller (this codebase's existing
 * pattern, e.g. `AccountScreen`'s "Bluetooth" label above its status row),
 * not this control's built-in `label` slot.
 */
@Composable
fun BeidTextField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    isError: Boolean,
    modifier: Modifier = Modifier,
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        placeholder = { Text(placeholder) },
        isError = isError,
        singleLine = true,
        keyboardOptions = keyboardOptions,
        shape = RoundedCornerShape(BeidRadius.control),
        colors = OutlinedTextFieldDefaults.colors(
            focusedTextColor = BeidTheme.colors.textPrimary,
            unfocusedTextColor = BeidTheme.colors.textPrimary,
            errorTextColor = BeidTheme.colors.textPrimary,
            focusedContainerColor = BeidTheme.colors.surfaceRaised,
            unfocusedContainerColor = BeidTheme.colors.surfaceRaised,
            errorContainerColor = BeidTheme.colors.surfaceRaised,
            focusedPlaceholderColor = BeidTheme.colors.textSecondary,
            unfocusedPlaceholderColor = BeidTheme.colors.textSecondary,
            errorPlaceholderColor = BeidTheme.colors.textSecondary,
            // iOS's EventCodeEntryView never varies the field's own border/cursor
            // color on error — only the message below it changes — so the error
            // variant mirrors the unfocused/normal one instead of Material3's
            // stock red, keeping this control visually identical to iOS on error.
            focusedBorderColor = BeidTheme.colors.actionPrimary,
            unfocusedBorderColor = BeidTheme.colors.strokeHairline,
            errorBorderColor = BeidTheme.colors.strokeHairline,
            cursorColor = BeidTheme.colors.actionPrimary,
            errorCursorColor = BeidTheme.colors.actionPrimary,
        ),
        modifier = modifier.fillMaxWidth(),
    )
}
