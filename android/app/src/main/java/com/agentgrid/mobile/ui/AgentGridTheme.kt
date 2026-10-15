package com.agentgrid.mobile.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import com.agentgrid.mobile.R

val PixelFontFamily = FontFamily(
    Font(R.font.fusion_pixel_12px_zh_hans, FontWeight.Normal),
    Font(R.font.fusion_pixel_12px_zh_hans, FontWeight.Medium),
    Font(R.font.fusion_pixel_12px_zh_hans, FontWeight.Bold),
)

object AgentGridColors {
    val Background = Color(0xFF05070B)
    val Surface = Color(0xFF0B1018)
    val SurfaceRaised = Color(0xFF101824)
    val Divider = Color(0xFF18212E)
    val Text = Color(0xFFE8EDF5)
    val Muted = Color(0xFF7F8A9A)
    val Dimmed = Color(0xFF4F5968)
    val Blue = Color(0xFF60A5FA)
    val Cyan = Color(0xFF5EEAD4)
    val Violet = Color(0xFFA78BFA)
    val Magenta = Color(0xFFE879F9)
    val Indigo = Color(0xFF818CF8)
    val Orange = Color(0xFFFB923C)
    val Amber = Color(0xFFFDBA4A)
    val Yellow = Color(0xFFFACC15)
    val Green = Color(0xFF4ADE80)
    val Red = Color(0xFFFB7185)
}

private val darkColors = darkColorScheme(
    primary = AgentGridColors.Amber,
    onPrimary = AgentGridColors.Background,
    secondary = AgentGridColors.Blue,
    onSecondary = AgentGridColors.Text,
    background = AgentGridColors.Background,
    onBackground = AgentGridColors.Text,
    surface = AgentGridColors.Surface,
    onSurface = AgentGridColors.Text,
    error = AgentGridColors.Red,
    onError = AgentGridColors.Background,
)

private val baseTypography = Typography()
private val pixelTypography = Typography(
    displayLarge = baseTypography.displayLarge.copy(fontFamily = PixelFontFamily),
    displayMedium = baseTypography.displayMedium.copy(fontFamily = PixelFontFamily),
    displaySmall = baseTypography.displaySmall.copy(fontFamily = PixelFontFamily),
    headlineLarge = baseTypography.headlineLarge.copy(fontFamily = PixelFontFamily),
    headlineMedium = baseTypography.headlineMedium.copy(fontFamily = PixelFontFamily),
    headlineSmall = baseTypography.headlineSmall.copy(fontFamily = PixelFontFamily),
    titleLarge = baseTypography.titleLarge.copy(fontFamily = PixelFontFamily),
    titleMedium = baseTypography.titleMedium.copy(fontFamily = PixelFontFamily),
    titleSmall = baseTypography.titleSmall.copy(fontFamily = PixelFontFamily),
    bodyLarge = baseTypography.bodyLarge.copy(fontFamily = PixelFontFamily),
    bodyMedium = baseTypography.bodyMedium.copy(fontFamily = PixelFontFamily),
    bodySmall = baseTypography.bodySmall.copy(fontFamily = PixelFontFamily),
    labelLarge = baseTypography.labelLarge.copy(fontFamily = PixelFontFamily),
    labelMedium = baseTypography.labelMedium.copy(fontFamily = PixelFontFamily),
    labelSmall = baseTypography.labelSmall.copy(fontFamily = PixelFontFamily),
)

@Composable
fun AgentGridTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = darkColors,
        typography = pixelTypography,
        content = content,
    )
}
