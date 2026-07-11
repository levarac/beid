package org.levarac.beid.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/**
 * Type ramp ported from DESIGN.md §6 "Typography" / iOS `DS.Font`. iOS uses
 * Dynamic Type system text styles (SF Pro); Android's equivalent is Material3
 * [Typography] roles, which scale with the user's font-size setting the same
 * way Dynamic Type does. Role → Material3 mapping (roughly size-for-size at
 * the default scale):
 *
 * | DS.Font          | Material3 role     |
 * |------------------|---------------------|
 * | screenTitle       | headlineLarge       |
 * | ceremonyTitle     | headlineMedium      |
 * | sectionTitle      | titleLarge          |
 * | cardTitle         | titleMedium         |
 * | body              | bodyLarge           |
 * | supporting        | bodyMedium          |
 * | meta              | labelSmall          |
 * | ledgerMono        | bodySmall (monospace)|
 * | cta               | labelLarge          |
 */
internal val BeidTypography = Typography(
    headlineLarge = TextStyle(fontWeight = FontWeight.Bold, fontSize = 32.sp, lineHeight = 40.sp),
    headlineMedium = TextStyle(fontWeight = FontWeight.Bold, fontSize = 24.sp, lineHeight = 30.sp),
    titleLarge = TextStyle(fontWeight = FontWeight.SemiBold, fontSize = 20.sp, lineHeight = 26.sp),
    titleMedium = TextStyle(fontWeight = FontWeight.SemiBold, fontSize = 16.sp, lineHeight = 22.sp),
    bodyLarge = TextStyle(fontWeight = FontWeight.Normal, fontSize = 16.sp, lineHeight = 24.sp),
    bodyMedium = TextStyle(fontWeight = FontWeight.Normal, fontSize = 14.sp, lineHeight = 20.sp),
    labelSmall = TextStyle(fontWeight = FontWeight.Normal, fontSize = 12.sp, lineHeight = 16.sp),
    bodySmall = TextStyle(
        fontWeight = FontWeight.Normal,
        fontSize = 13.sp,
        lineHeight = 18.sp,
        fontFamily = FontFamily.Monospace,
    ),
    labelLarge = TextStyle(fontWeight = FontWeight.SemiBold, fontSize = 16.sp, lineHeight = 22.sp),
)
