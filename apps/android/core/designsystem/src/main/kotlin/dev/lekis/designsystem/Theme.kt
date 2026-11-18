package dev.lekis.designsystem

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/** 主题模式（设置页可选）。 */
enum class ThemeMode { System, Light, Dark, OledBlack }

/** Material 没有的额外颜色。 */
@Immutable
data class LekisExtraColors(
    val moon: Color,
    val accentSoft: Color,
    val surfaceElevated: Color,
)

val LocalLekisColors = staticCompositionLocalOf {
    LekisExtraColors(
        moon = LekisTokens.Light.moon,
        accentSoft = LekisTokens.Light.accentSoft,
        surfaceElevated = LekisTokens.Light.surfaceElevated,
    )
}

private fun lightScheme(): ColorScheme = lightColorScheme(
    primary = LekisTokens.Light.accent,
    onPrimary = LekisTokens.Light.onAccent,
    primaryContainer = LekisTokens.Light.accentSoft,
    background = LekisTokens.Light.background,
    onBackground = LekisTokens.Light.onBackground,
    surface = LekisTokens.Light.surface,
    onSurface = LekisTokens.Light.onSurface,
    surfaceVariant = LekisTokens.Light.surfaceVariant,
    onSurfaceVariant = LekisTokens.Light.onSurfaceVariant,
    outline = LekisTokens.Light.outline,
    error = LekisTokens.Light.danger,
)

private fun darkScheme(oled: Boolean): ColorScheme = darkColorScheme(
    primary = LekisTokens.Dark.accent,
    onPrimary = LekisTokens.Dark.onAccent,
    primaryContainer = LekisTokens.Dark.accentSoft,
    background = if (oled) LekisTokens.OledBlack.background else LekisTokens.Dark.background,
    onBackground = LekisTokens.Dark.onBackground,
    surface = if (oled) LekisTokens.OledBlack.surface else LekisTokens.Dark.surface,
    onSurface = LekisTokens.Dark.onSurface,
    surfaceVariant = LekisTokens.Dark.surfaceVariant,
    onSurfaceVariant = LekisTokens.Dark.onSurfaceVariant,
    outline = LekisTokens.Dark.outline,
    error = LekisTokens.Dark.danger,
)

/** 字号对应 tokens.json 的 typography。中文使用系统默认字体。 */
private val LekisTypography = Typography(
    displaySmall = TextStyle(fontSize = 34.sp, lineHeight = 40.sp, fontWeight = FontWeight.Bold),
    headlineMedium = TextStyle(fontSize = 28.sp, lineHeight = 34.sp, fontWeight = FontWeight.Bold),
    titleLarge = TextStyle(fontSize = 22.sp, lineHeight = 28.sp, fontWeight = FontWeight.SemiBold),
    titleMedium = TextStyle(fontSize = 17.sp, lineHeight = 22.sp, fontWeight = FontWeight.SemiBold),
    bodyLarge = TextStyle(fontSize = 15.sp, lineHeight = 20.sp),
    bodyMedium = TextStyle(fontSize = 14.sp, lineHeight = 19.sp),
    labelSmall = TextStyle(fontSize = 12.sp, lineHeight = 16.sp),
)

private val LekisShapes = Shapes(
    extraSmall = RoundedCornerShape(LekisTokens.Radius.xs),
    small = RoundedCornerShape(LekisTokens.Radius.sm),
    medium = RoundedCornerShape(LekisTokens.Radius.md),
    large = RoundedCornerShape(LekisTokens.Radius.lg),
    extraLarge = RoundedCornerShape(LekisTokens.Radius.xl),
)

/** 歌词专用字号（正在播放页）。 */
val LyricsActiveStyle = TextStyle(fontSize = 30.sp, lineHeight = 38.sp, fontWeight = FontWeight.Bold)

@Composable
fun LekisTheme(mode: ThemeMode = ThemeMode.System, content: @Composable () -> Unit) {
    val dark = when (mode) {
        ThemeMode.System -> isSystemInDarkTheme()
        ThemeMode.Light -> false
        ThemeMode.Dark, ThemeMode.OledBlack -> true
    }
    val scheme = if (dark) darkScheme(oled = mode == ThemeMode.OledBlack) else lightScheme()
    val extra = if (dark) {
        LekisExtraColors(LekisTokens.Dark.moon, LekisTokens.Dark.accentSoft, LekisTokens.Dark.surfaceElevated)
    } else {
        LekisExtraColors(LekisTokens.Light.moon, LekisTokens.Light.accentSoft, LekisTokens.Light.surfaceElevated)
    }
    androidx.compose.runtime.CompositionLocalProvider(LocalLekisColors provides extra) {
        MaterialTheme(colorScheme = scheme, typography = LekisTypography, shapes = LekisShapes, content = content)
    }
}
